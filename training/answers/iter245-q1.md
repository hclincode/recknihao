# Iter245 Q1 — EXPLAIN ANALYZE VERBOSE for Slow Federated Query Diagnosis

## Answer

Your question gets at the heart of federated query diagnosis on Trino. `EXPLAIN ANALYZE VERBOSE` outputs a lot of information, but there are only a few fields that actually matter for your problem. Let me walk you through what to look for and what it tells you about Postgres being the bottleneck.

### The fields you actually care about

In a real `EXPLAIN ANALYZE` output, you'll see operator blocks like this (abbreviated):

```
Fragment N [...]
    CPU: 8.12s, Scheduled: 40.05s, Blocked: 29.80s (Input: 28.50s, Output: 1.62s)
    Input: 12500000 rows (450MB), Physical Input: 2.10GB
```

**The three fields that matter for your bottleneck hunt:**

1. **`Scheduled:`** — Total wall-clock time this operator spent running on workers. This is your actual elapsed time per operator. Use this (not "Wall time" — that field doesn't exist in Trino 467).

2. **`CPU:` vs `Scheduled:` gap** — If `Scheduled:` is much larger than `CPU:` (e.g., 40s scheduled but only 8s CPU), the operator spent most of its time **blocked, not computing**. That's your indicator of I/O bottleneck. Specifically, when `Blocked: Input` is high, the operator is waiting on data from upstream.

3. **`Physical Input:`** — The actual bytes read from the data source. For the Postgres scan operator, this tells you how much data Trino actually pulled from Postgres.

### Rows vs Physical Input — the critical distinction

- **`Input: N rows`** — The number of *logical rows* that passed through this operator. This is after any filters or joins. For a Postgres scan with a `WHERE` clause, this should be smaller than the total table size if the filter worked.

- **`Physical Input: M GB`** — The actual *compressed bytes* Trino read from Postgres. This is what tells you whether Trino is pulling way more data than necessary.

**The gap between the two is your smoking gun.** If your Postgres scan says:
```
Input: 5 million rows (200 MB)
Physical Input: 50 GB
```

Then Trino pulled 50 GB from Postgres but only ended up using 200 MB of it — that's your "pulling way more data than it needs" problem.

### How to tell if Postgres (not Trino) is the bottleneck

Look at the **Postgres scan operator** in your `EXPLAIN ANALYZE` output. Find the line that mentions `ScanFilterProject` or `Scan` on the `app_pg` catalog:

1. **Is `Scheduled:` >> `CPU:`?** (e.g., 30s scheduled, 2s CPU) → Postgres side is I/O-bound. Trino's workers are sitting around waiting for Postgres to send data.

2. **Is `Blocked: Input` high relative to `Scheduled:`?** → Workers are blocked waiting on the network from Postgres.

3. **Is `Physical Input:` unexpectedly large?** If you expect 1 GB of customer data from Postgres but `Physical Input:` says 50 GB, predicate pushdown isn't working.

### The Iceberg side — for comparison

Look at your Iceberg scan operator(s). Compare:
- Does Iceberg's `Physical Input:` match what you'd expect from partition pruning? (If you filtered to one day, you should see ~1 day's data, not a year's.)
- Is Iceberg's `Scheduled:` closer to `CPU:`? If so, Iceberg is compute-bound (good), not I/O-bound.

If Iceberg looks fine but Postgres `Scheduled:` is 10x higher, **Postgres is your bottleneck**.

### To confirm predicate pushdown is working

**Canonical check**: In plain `EXPLAIN` output (not VERBOSE), look for the **absence of a `ScanFilterProject` operator above the `TableScan` for Postgres**. If pushdown succeeded, only `TableScan` appears. If pushdown failed, `ScanFilterProject` appears above `TableScan` — meaning Trino pulled all rows from Postgres and filtered them locally.

Run the query with `EXPLAIN ANALYZE VERBOSE`:

```sql
EXPLAIN ANALYZE VERBOSE
SELECT c.*, e.event_type, COUNT(*)
FROM app_pg.public.accounts c
JOIN iceberg.analytics.events e ON c.account_id = e.account_id
WHERE c.plan = 'enterprise'
  AND e.occurred_at >= TIMESTAMP '2026-05-01 00:00:00'
GROUP BY c.account_id, c.name, e.event_type;
```

> **Warning**: `EXPLAIN ANALYZE VERBOSE` actually runs the query in full. A 45-second slow query takes 45 seconds to diagnose this way. Use plain `EXPLAIN` first to check the plan structure cheaply, then escalate to VERBOSE only when you need runtime numbers.

`EXPLAIN ANALYZE VERBOSE` adds:
- Per-operator wall time and dynamic filter wait timings
- Input distribution percentiles across workers
- Actual dynamic filter values applied
- Per-driver memory usage

Look for a **`Filter:` line in the Postgres scan operator**. It should show something like:
```
Filter: plan = 'enterprise'
```

If the filter line is **missing**, or says `Filter: true` (no filtering), then **Postgres didn't get the WHERE clause** — Trino pulled all `app_pg.public.accounts` rows and filtered them on the coordinator. That's your data-pulling problem.

### What's actually happening under the hood

Your federated join works like this:

1. Trino scans both sides (Postgres and Iceberg).
2. The **smaller table becomes the build side** — Trino builds a hash table from it.
3. The dynamic filter from the build side is pushed INTO the probe side to prune its scan before reading.
4. For your query: if Postgres customers (smaller) = build side, the customer join keys are collected into a filter and pushed INTO the Iceberg event scan to prune files. Postgres itself still gets scanned in full unless predicate pushdown works on your WHERE clause.

When Postgres is slow:
- Postgres itself might be slow (index scan not working, filters not pushed down, sequential scan)
- Trino might be pulling all rows and filtering client-side instead of pushing the filter to Postgres
- The JDBC connection is single-threaded — 1 connection streams all data sequentially

### A concrete next-step checklist

1. **Run `EXPLAIN` (not ANALYZE) first** — cheap, no query execution. Look for `ScanFilterProject` above the Postgres scan. If present, pushdown failed.
2. **If pushdown failed**: check if your `WHERE` clause column is VARCHAR with a range filter — VARCHAR range predicates (`<`, `>`, `BETWEEN`) don't push down by default. Use equality (`=`) or `IN` instead.
3. **Run `EXPLAIN ANALYZE VERBOSE`** for runtime numbers. Look at the Postgres scan operator: `Scheduled:` >> `CPU:` = I/O-bound; `Physical Input:` > expected = too much data pulled.
4. **Check `dynamicFilterSplitsProcessed`** in VERBOSE output — this tells you if dynamic filtering fired to prune the Iceberg side based on the join keys.
5. **If Postgres scan shows correct filter but is still slow**: the issue is on Postgres itself — check `pg_stat_activity` for query duration, and add an index on the filtered column.
