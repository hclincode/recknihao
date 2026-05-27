# Iter260 Q2 — EXPLAIN ANALYZE: Diagnosing Where a Slow Federated Query Spends Its Time

## Answer

Your frustration with the Trino UI is completely understandable — there are a lot of boxes and numbers. The good news is that Trino gives you several tools to pinpoint exactly where slowness lives, and you can use them in a straightforward 3-step workflow that takes minutes instead of guessing.

### Understanding the problem: three places slowness can hide

When your query sometimes runs in 5 seconds and sometimes takes 30, the slowness is almost always one of three things:

1. **Postgres (or another source) is slow returning data** — the JDBC connection is waiting for rows to arrive over the network, or Postgres's own query plan is slow.
2. **Trino is doing heavy processing** — a join, an aggregation, or a window function on Trino workers is taking CPU time.
3. **The planning phase** — before execution even starts, Trino spent time analyzing the query and building an execution plan.

---

### Step 1: Check planning time (the fast pre-screening)

Start with the fastest diagnostic: query Trino's built-in `system.runtime.queries` table to see how much time went into the planning phase:

```sql
SELECT 
  query_id,
  "user",
  source,
  planning_time_ms,
  queued_time_ms,
  analysis_time_ms,
  created,
  "end"
FROM system.runtime.queries
WHERE query LIKE '%your_federated_query_pattern%'
  AND state = 'FINISHED'
ORDER BY created DESC
LIMIT 20;
```

**What you're looking for:**
- If `planning_time_ms` is greater than a few seconds (say, > 5000 ms), planning is the bottleneck. This is especially common with federated queries involving multiple catalogs — Trino is fetching metadata and statistics from Postgres, scanning Iceberg manifest files, and running the cost-based optimizer.
- If `planning_time_ms` is under 1 second but the total elapsed time is 30 seconds, the problem is in execution, not planning. Move to Step 2.

**Important note on system.runtime.queries**: the column `"user"` must be double-quoted (unquoted `user` gets interpreted as the `current_user()` function). There is **no `catalog` column** — you have to filter by searching the SQL text with `LIKE`. This table is also ephemeral and gets wiped on coordinator restarts.

---

### Step 2: Run EXPLAIN ANALYZE to see operator-level execution stats

Once you know planning wasn't the problem, run the query with `EXPLAIN ANALYZE`:

```sql
EXPLAIN ANALYZE SELECT ...your federated query...;
```

**Critical warning**: `EXPLAIN ANALYZE` actually executes the full query. If your slow query runs for 30 minutes, EXPLAIN ANALYZE will also take 30 minutes. Always run a plain `EXPLAIN (TYPE DISTRIBUTED)` first (which only does planning) if you want to see the structure without paying the execution cost.

The output is structured as a tree of operators. Here is what to look for:

#### For the Postgres TableScan operator (the JDBC scan):

```
TableScan[table = app_pg:public.orders, ...]
    Input: 52000 rows (4.51MB)
    Output: 52000 rows
    CPU: 1.23s
    Elapsed: 2.50s
    Wall: 2.45s
    constraint on [status, order_date]
        status = 'active'
        order_date >= DATE '2026-05-01'
```

**Read these fields in order:**

1. **`Input: N rows` vs `Output: N rows`** — This is the single most direct signal. If you see `Input: 5,200,000 rows` but `Output: 200,000 rows` AND there is a `Filter` node sitting above the TableScan in the plan, then **Trino fetched all 5.2M rows over JDBC and filtered them locally on Trino workers**. This is a strong sign that predicate pushdown failed — Postgres never saw the WHERE clause. Conversely, if Input and Output are both small and the `constraint on` block shows your predicates, pushdown succeeded.

2. **`Physical Input`** — the total bytes received over JDBC. For a JDBC scan, this is uncompressed row data on the network. If this number is large relative to the final output (e.g., scanning 500MB but returning only 10K rows), Trino had to pull a lot of data from Postgres.

3. **`dynamicFilterSplitsProcessed = N`** — Shows whether dynamic filtering actually worked at runtime. If this is 0 BUT you see a `DynamicFilter` annotation elsewhere in the plan, it means the dynamic filter was wired up but didn't fire because the build side took too long to finish before the timeout expired (the default is 20 seconds for Postgres). If this is > 0, dynamic filtering worked and pruned rows on the Postgres side.

4. **Operator timing (`CPU` / `Elapsed` / `Wall`)** — Wall time is the real clock time the operator spent. If the Postgres TableScan's wall time is > 80% of the total query time, **Postgres is your bottleneck**.

#### For the join or aggregation operators:

Look at the same `Input` / `Output` pattern and the `CPU` / `Wall` time. If a join operator has high CPU time or high `Elapsed` time relative to the Postgres TableScan, then **Trino workers are the bottleneck**.

#### Example diagnosis:

Imagine you see:
```
TableScan[app_pg:orders] 
  Input: 5200000 rows (450MB)
  Wall: 15.23s

Join[condition = ...]
  Input: 5200000 rows
  Wall: 2.10s
```

The Postgres scan took 15 seconds (wall time) and returned 5.2M rows. The join took only 2 seconds. **This is telling you: 88% of the slowness is waiting for Postgres to return rows.** The fix is not to optimize the join — it's to get Postgres to return fewer rows (tighten the WHERE clause, enable dynamic filtering, or add an index on Postgres).

---

### Step 3: Check Postgres directly (the ground truth)

While your slow Trino query is running (or immediately after it completes), check what Postgres is actually executing:

```sql
-- On the Postgres replica, as a user with sufficient privileges:
SELECT pid, query_start, state, query
FROM pg_stat_activity
WHERE usename = 'trino_reader';
```

This shows the actual SQL that Trino sent to Postgres and how long it's been running. If the query shows `SELECT col1, col2, ... FROM orders` with no WHERE clause, **predicate pushdown failed** — Trino fetched the entire table. If the query shows `SELECT ... WHERE status = 'active' AND order_date >= ...`, pushdown succeeded.

You can also manually run that exact SQL in `psql` with `EXPLAIN ANALYZE` to see what Postgres's own query plan thinks:

```sql
-- In psql, run the exact query Postgres received:
EXPLAIN ANALYZE SELECT ... FROM orders WHERE status = 'active' ...;
```

---

### The 3-step practical workflow

1. **Quick check — `system.runtime.queries`**: Does `planning_time_ms > 5000`? If yes, simplify the query. If no, continue.
2. **Detailed check — `EXPLAIN ANALYZE`**: Compare the Postgres TableScan's wall time to the overall query wall time. Is the TableScan > 80% of total? If yes, Postgres is the bottleneck. If no, a join or aggregation on Trino workers is the bottleneck.
3. **Ground truth check — `pg_stat_activity`**: During a slow query, run this to see the exact SQL Trino sent. If it's missing WHERE clauses, predicates didn't push down.

---

### About that Trino Web UI wall of boxes

The query detail page in the Trino UI shows a timeline and operators for each stage of the query. The timeline view does show stage-level wall times (how long each stage took), which can help you see if one stage is much slower than others. But the real value is in the **textual EXPLAIN ANALYZE output** — that's where you get the row counts and CPU timings that tell you exactly where time was spent. The UI is useful for a quick visual sanity check ("oh, that stage took 25 seconds while this one took 1 second"), but for true diagnosis, the numbers in EXPLAIN ANALYZE output are what matter.

---

### Why variability (5 seconds vs 30 seconds)?

Slow federated queries often vary in runtime because:
- **Postgres query caching or plan changes**: Postgres's buffer cache might be warm sometimes and cold other times. The query planner might choose different indexes depending on table statistics.
- **Dynamic filtering timeout**: If build-side stats indicate a small join key cardinality, Trino might apply a dynamic filter to prune Postgres results. If the build side is slow to produce those values, the dynamic filter times out (default 20 seconds) and the Postgres scan runs unfiltered. Check `dynamicFilterSplitsProcessed` in EXPLAIN ANALYZE.
- **Network or resource contention**: JDBC connections are sometimes slower than other times. Check if other queries are running concurrently on the same cluster.

The diagnostic steps above will pinpoint which of these is happening in your case.
