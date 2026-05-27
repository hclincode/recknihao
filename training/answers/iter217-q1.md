# Iter 217 Q1 — Understanding Trino EXPLAIN ANALYZE for Federated Queries

## Answer

## Understanding Trino EXPLAIN ANALYZE for Federated Queries

Your 30-second query joining Iceberg (S3), PostgreSQL, and MySQL data is hitting a performance wall somewhere — and the EXPLAIN ANALYZE output will tell you exactly where if you know what to read. Let me walk you through it.

### How to run EXPLAIN ANALYZE on a distributed query

First, the critical difference between EXPLAIN modes:

```sql
-- Option 1: Plan-only (cheap, does not execute the query)
EXPLAIN (TYPE DISTRIBUTED)
SELECT e.event_id, e.occurred_at, u.email, b.invoice_id
FROM iceberg.analytics.events e
JOIN app_pg.public.users u ON e.user_id = u.id
JOIN billing_mysql.public.invoices b ON u.tenant_id = b.tenant_id
WHERE e.occurred_at >= CURRENT_DATE - INTERVAL '7' DAY;

-- Option 2: Full execution with runtime metrics (expensive, re-runs the query)
EXPLAIN ANALYZE
SELECT e.event_id, e.occurred_at, u.email, b.invoice_id
FROM iceberg.analytics.events e
JOIN app_pg.public.users u ON e.user_id = u.id
JOIN billing_mysql.public.invoices b ON u.tenant_id = b.tenant_id
WHERE e.occurred_at >= CURRENT_DATE - INTERVAL '7' DAY;
```

Use `EXPLAIN (TYPE DISTRIBUTED)` first — it's free and tells you if dynamic filtering is wired up at plan time. When you've found the slow piece, use `EXPLAIN ANALYZE` to see actual runtime metrics like how many rows each side really produced and how much I/O happened.

### Reading the distributed plan output

A real Trino distributed plan has multiple **Fragments**, each representing a portion of work that can run in parallel on Trino workers. The plan output you'll see looks like:

```
Fragment 0 [SINGLE]
  Output[...]
  └─ Aggregate(...)
       └─ Join[inner]
            ├─ Exchange[type=REPARTITION]
            │   └─ TableScan[table = app_pg:public.users, constraint = ...]
            │       Layout: [id, tenant_id, email]
            │
            └─ Exchange[type=REPARTITION]
                └─ TableScan[table = iceberg:analytics.events, 
                              constraint = (occurred_at >= DATE '2026-05-19'),
                              dynamicFilters = {df_user_id_0 = ...}]
                    Input: 45000000 rows
                    Physical Input: 500MB

Fragment 1 [SOURCE]
  TableScan[table = app_pg:public.users]
      Estimates: {rows: 2.5M, ...}

Fragment 2 [SOURCE]
  TableScan[table = iceberg:analytics.events, ...]
      Estimates: {rows: 300M, ...}
```

Here's what each piece means:

**Fragments** represent distinct distributed work units. Each `[SOURCE]` fragment scans a different data source (one Fragment for Postgres, one for Iceberg, one for MySQL). The coordinator collects results and performs final operations (aggregations, output). Think of Fragments as "stages in a MapReduce job" — each one runs independently on workers.

**Fragment labels** — the brackets tell you what type of work:
- `[SOURCE]` — a scan fragment (reads from storage: Iceberg, Postgres, MySQL, etc.)
- `[SINGLE]` — runs on only one worker (usually final aggregation or output)
- There are also intermediate fragments that do exchanges/shuffles

**Exchanges** — the `Exchange[type=...]` nodes show network shuffles between fragments. Two types you'll see:
- `Exchange[type=REPARTITION]` — hash both sides of a join by the join key and shuffle across workers. This is the expensive "partitioned join" path (adds network I/O).
- `Exchange[type=REPLICATE]` — broadcast the smaller side to every worker (the efficient "broadcast join" path).

### What "broadcast join" actually means in the output

When you see a broadcast join in the plan, it shows up as `Exchange[type=REPLICATE]` on the **smaller side's exchange**:

```
Join[inner]
  ├─ Exchange[type=REPLICATE]           <-- broadcast (small side goes to every worker)
  │   └─ TableScan[table = app_pg:public.users, ...]
  │
  └─ Exchange[type=REPARTITION]         <-- shuffle (large side repartitions)
      └─ TableScan[table = iceberg:analytics.events, ...]
```

This is **good** — it means Trino's cost-based optimizer (CBO) decided the Postgres `users` table fits in worker memory, so it broadcasts a copy to every worker. Each worker then joins its local slice of the Iceberg `events` table against the full `users` in memory. No shuffle of the huge fact table — fast.

The opposite (partitioned join) would show `REPARTITION` on both sides — more expensive because it shuffles the massive Iceberg table across the network.

### Understanding `dynamicFilterSplitsProcessed` — the key metric for federation

This is where your bottleneck diagnosis becomes concrete. Here's the critical rule:

**`dynamicFilterSplitsProcessed` appears on the PROBE side, not the build side.** If you're joining a small Postgres dimension to a large Iceberg fact table, the Postgres side is the "build" (small, hashed), and the Iceberg side is the "probe" (large, scanned). The metric will be **on the Iceberg `TableScan` node**, not the Postgres node.

What it means: after Trino finishes building the hash table from the small side (Postgres), it extracts a runtime filter (an IN-list or range) from the join keys and pushes it to the probe side's scan. The probe side (Iceberg) then skips data files or partitions that can't match any value in that filter. The `dynamicFilterSplitsProcessed` number tells you **how many data splits the probe side skipped because of this filter**.

Example output:

```
Fragment 2 [SOURCE]
  TableScan[table = iceberg:analytics.events,
            constraint = (occurred_at >= TIMESTAMP '2026-05-19 00:00:00'),
            dynamicFilters = {df_user_id_0 = [1000 values]}]
      Input: 2500000 rows (150MB), Physical Input: 150MB
      dynamicFilterSplitsProcessed: 185 / 200 splits skipped
```

Translation: the Iceberg scan started with 200 splits (chunks of Parquet files). Dynamic filtering pruned 185 of them because the Postgres join key values didn't match. Only 5 splits were actually read, saving 95% of the I/O. **This is working well.**

If instead you see:

```
Fragment 2 [SOURCE]
  TableScan[table = iceberg:analytics.events,
            constraint = (occurred_at >= TIMESTAMP '2026-05-19 00:00:00'),
            dynamicFilters = {df_user_id_0 = [50000 values]}]
      Input: 125000000 rows (3.5GB), Physical Input: 3.5GB
      dynamicFilterSplitsProcessed: 0 / 200 splits skipped
```

Translation: dynamic filtering was wired up (you see the `dynamicFilters = ...` annotation), but **zero splits were pruned**. The Postgres side had too many distinct user IDs (50,000), so the dynamic filter became too large to use effectively. Or, the Postgres scan was slow and the Iceberg scan started before the filter arrived. Either way: the probe side is reading every file, defeating the purpose of the join.

### Pinpointing which data source is the bottleneck

Now you can read the plan to find the culprit. Here's the diagnostic checklist:

**1. Look at each Fragment's actual I/O**

In the EXPLAIN ANALYZE output, each `TableScan` node shows `Physical Input:` — the actual bytes read from that data source.

```
Fragment 1 [SOURCE] — Postgres
  TableScan[table = app_pg:public.users, ...]
      Physical Input: 50MB
      
Fragment 2 [SOURCE] — Iceberg  
  TableScan[table = iceberg:analytics.events, ...]
      Physical Input: 3.5GB
      
Fragment 3 [SOURCE] — MySQL
  TableScan[table = billing_mysql:public.invoices, ...]
      Physical Input: 2.1GB
```

**The source reading the most bytes is your first suspect.** In this example, Iceberg is reading 3.5 GB. The question then becomes: is 3.5 GB correct for this query, or is a filter supposed to prune it down?

**2. Check if predicates pushed down to each source**

Look at the `constraint = ...` field on each `TableScan`:

```
TableScan[table = app_pg:public.users, 
          constraint = (plan = 'enterprise' AND status = 'active')]
    # Good — Postgres received the filter server-side
    
TableScan[table = iceberg:analytics.events,
          constraint = (occurred_at >= TIMESTAMP '2026-05-19 00:00:00')]
    # Good — Iceberg received the date filter at plan time
    
TableScan[table = billing_mysql:public.invoices]
    # BAD — no constraint — MySQL is reading EVERY row, then Trino filters afterward
```

If you see no `constraint =` on a TableScan, it means either:
- The WHERE clause didn't include that table's filter column, or
- The optimizer couldn't push the predicate down to that connector.

For Postgres and MySQL, predicate pushdown is usually reliable. If you wrote `WHERE user.plan = 'enterprise'` and the Postgres scan shows no constraint, double-check your WHERE clause syntax and column names.

**3. Check dynamic filtering is firing on probe-side scans**

For each cross-catalog join, look for `dynamicFilters = {...}` on the **large side** (probe), not the small side (build):

```
# This is CORRECT — the large Iceberg scan received a DF from Postgres:
TableScan[table = iceberg:analytics.events,
          dynamicFilters = {df_user_id_0 = [150K values]}]
    dynamicFilterSplitsProcessed: 50 / 200

# This is a PROBLEM — the large Iceberg scan has NO DF annotation:
TableScan[table = iceberg:analytics.events]
    # No dynamicFilters line — DF did not fire, or CBO did not wire it up
```

If a large probe-side scan has no `dynamicFilters` annotation in EXPLAIN ANALYZE, the join is reading data unnecessarily.

**4. Compare wall-clock time vs compute time to isolate I/O vs CPU bottlenecks**

In EXPLAIN ANALYZE output, each operator shows:

```
CPU: 8.12s, Scheduled: 40.05s, Blocked: 29.80s (Input: 28.50s, Output: 1.62s)
```

Translation:
- **CPU: 8.12s** — time spent actually computing (joining, filtering, aggregating)
- **Scheduled: 40.05s** — total wall-clock time this operator was busy (includes waiting)
- **Blocked: Input: 28.50s** — time spent waiting for upstream data (storage I/O, network)

The quick rule:
- If `Scheduled` is much larger than `CPU` (e.g., 5–10x), the operator is **I/O-bound**. It's waiting on storage, not compute.
- If `Scheduled` ≈ `CPU`, the operator is **compute-bound**. The problem is the join itself, not data volume.

### Concrete example: diagnosing your 30-second query

Let's say your actual EXPLAIN ANALYZE output is:

```
Fragment 0 [SINGLE]
  Aggregate
    └─ Join[inner]
         CPU: 3.2s, Scheduled: 8.5s, Blocked: 5.3s (Input: 5.1s, Output: 0.2s)

Fragment 1 [SOURCE] — Postgres
  TableScan[table = app_pg:public.users,
            constraint = (tenant_id IN (50 values))]
      Input: 150K rows, Physical Input: 12MB
      CPU: 0.8s, Scheduled: 2.1s, Blocked: 1.3s (Input: 1.3s, Output: 0s)

Fragment 2 [SOURCE] — Iceberg
  TableScan[table = iceberg:analytics.events,
            constraint = (occurred_at >= TIMESTAMP '2026-05-19'),
            dynamicFilters = {df_user_id_0 = [150K values]}]
      Input: 3.2M rows, Physical Input: 1.8GB
      CPU: 5.1s, Scheduled: 18.2s, Blocked: 13.1s (Input: 13.1s, Output: 0s)
      dynamicFilterSplitsProcessed: 30 / 150 splits

Fragment 3 [SOURCE] — MySQL
  TableScan[table = billing_mysql:public.invoices]
      Input: 12M rows, Physical Input: 4.2GB
      CPU: 0.3s, Scheduled: 12.5s, Blocked: 12.2s (Input: 12.2s, Output: 0s)
      # NOTE: no constraint — MySQL is reading ALL invoices, not filtered
```

**Diagnosis:**

1. **Postgres is fast** — 12 MB, 0.8s CPU, small `Blocked: Input` time. Not the bottleneck.

2. **Iceberg is slow-ish** — 1.8 GB read, 5.1s CPU, 13.1s blocked on input. Dynamic filtering helped (pruned 30/150 splits), but it still read 1.8 GB. The date filter should have pruned it further if the table is properly partitioned by `occurred_at`. Check: does the table have a `partitioning = ARRAY['day(occurred_at)']` or similar? If yes, why is the filter not pushing down?

3. **MySQL is the killer** — 4.2 GB read, 12.2s blocked waiting on I/O, and **zero constraint in the plan**. MySQL is reading every invoice in the database. You almost certainly have a missing WHERE clause — something like `WHERE b.invoice_date >= ?` is not in your SQL. Or the column name is different on the MySQL side.

**The fix:** Add explicit filters to your query:

```sql
SELECT e.event_id, e.occurred_at, u.email, b.invoice_id
FROM iceberg.analytics.events e
JOIN app_pg.public.users u ON e.user_id = u.id
JOIN billing_mysql.public.invoices b ON u.tenant_id = b.tenant_id
WHERE e.occurred_at >= CURRENT_DATE - INTERVAL '7' DAY      -- Iceberg filter
  AND u.status = 'active'                                    -- Postgres filter
  AND b.invoice_date >= CURRENT_DATE - INTERVAL '30' DAY;   -- MySQL filter (missing before!)
```

Then re-run `EXPLAIN ANALYZE` and verify that `billing_mysql.public.invoices` now shows a `constraint = ...` on its TableScan.

---

## Key takeaways

1. **Run `EXPLAIN (TYPE DISTRIBUTED)`** first to see the plan for free. Look for `dynamicFilters = {...}` on probe-side scans (large tables receiving runtime filters from small tables).

2. **Run `EXPLAIN ANALYZE`** on slow queries to see actual `Physical Input:` bytes and `dynamicFilterSplitsProcessed` metrics. This tells you how much data each source really read.

3. **`dynamicFilterSplitsProcessed` > 0 on a probe-side scan is good** — it means a runtime filter from the other side pruned data files or splits. If it's 0, either the build side had too many distinct values, or the build side was slow and the probe started before the filter arrived.

4. **Check for missing `constraint = ...` fields** on TableScans. If a source has no constraint, you're reading all its data on the Trino side, not pushing the filter down to the source. This is almost always a query bug (missing WHERE clause) or wrong join condition.

5. **Use `Scheduled:` vs `Blocked: Input`** to decide if the bottleneck is compute (join complexity) or I/O (storage/network). High `Blocked: Input` relative to `Scheduled:` means you're waiting on the data source — either it's slow, or you're reading too much.
