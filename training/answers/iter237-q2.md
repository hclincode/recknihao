# Iter 237 Q2 — Federation Observability: Diagnosing Slow Cross-Catalog Queries

## Answer

Your 30-40 second query is spending time in one of three places: the PostgreSQL scan via JDBC, the Iceberg file read, or the join operation itself. Trino has built-in diagnostics inside the query engine to isolate which one is the bottleneck — no external monitoring infrastructure required.

### Tool 1: EXPLAIN ANALYZE VERBOSE — The Gold Standard

This command actually runs your query and surfaces per-operator timing and metadata. Start here.

**What to look for on the PostgreSQL TableScan operator:**

- **`Physical Input`** (total bytes read from PostgreSQL over JDBC) — If this equals or approaches your full PostgreSQL table size, predicate pushdown failed and Trino fetched the entire table. If you expected 10,000 rows but Physical Input shows 5.2M rows (450MB), **that's your bottleneck** — JDBC throughput saturated pulling data PostgreSQL should have filtered server-side.

- **`Operator timing` (CPU / Elapsed / Wall time)** — If the PostgreSQL TableScan's elapsed time dominates the overall query, the PostgreSQL side is the bottleneck. Compare: if Iceberg scan takes 5 seconds and PostgreSQL takes 25 seconds, PostgreSQL is the problem.

- **`dynamicFilterSplitsProcessed = N`** (on the Iceberg scan) — A **non-zero value** means dynamic filtering fired and Iceberg was pruned. A **zero value** paired with a `dynamicFilters = {...}` annotation in the plan means dynamic filtering was wired up but timed out waiting for the build side.

**What to look for on the Iceberg TableScan operator:**

- **`Physical Input`** (total bytes read from Iceberg files) — A huge value (gigabytes) with a small result set means partition pruning or dynamic filtering is not working. Check whether your WHERE clause uses a partition column in a partition-aligned way.

- **Operator timing** — If Iceberg's elapsed time dominates, the bottleneck is Iceberg file I/O or lack of partition pruning.

**The practical workflow:**

```sql
-- Step 1: Run plain EXPLAIN first (no execution cost, just shows plan shape)
EXPLAIN (TYPE DISTRIBUTED)
SELECT u.email, COUNT(*) AS recent_events
FROM app_pg.public.users u
JOIN iceberg.analytics.events e ON e.user_id = u.id
WHERE u.status = 'active'
  AND e.event_time > TIMESTAMP '2026-05-26 00:00:00'
GROUP BY u.email;

-- Step 2: Run EXPLAIN ANALYZE VERBOSE (re-executes the full query — will take 30-40s)
EXPLAIN ANALYZE VERBOSE
SELECT u.email, COUNT(*) AS recent_events
FROM app_pg.public.users u
JOIN iceberg.analytics.events e ON e.user_id = u.id
WHERE u.status = 'active'
  AND e.event_time > TIMESTAMP '2026-05-26 00:00:00'
GROUP BY u.email;
```

In the output, compare the two `TableScan` nodes (PostgreSQL vs Iceberg) for Physical Input and elapsed times.

### Tool 2: system.runtime.queries — Real-Time Query State Monitoring

While the query is running, peek at its progress from a separate Trino session:

```sql
-- Find your running query (NOTE: double-quote "user" — it's a reserved keyword)
SELECT query_id, "user", source, state, created
FROM system.runtime.queries
WHERE query LIKE '%app_pg%'
  AND state = 'RUNNING'
ORDER BY created DESC
LIMIT 1;
```

**Key columns:**
- **`state`** — `RUNNING`, `FINISHED`, `FAILED`. A query stuck in `RUNNING` for too long indicates a slow operator.
- **`queued_time_ms`, `analysis_time_ms`, `planning_time_ms`** — Time before execution. Execution time = elapsed - (queued + analysis + planning).

The Trino Web UI at `http://<coordinator>:8080/ui/query.html?<query_id>` shows a visual operator timeline and per-operator row counts — often faster to read than raw EXPLAIN ANALYZE output.

### Tool 3: The Bottleneck Decision Tree

Once you have `EXPLAIN ANALYZE VERBOSE` output:

**1. Look at `dynamicFilterSplitsProcessed` on the Iceberg scan:**
- Non-zero? Dynamic filtering fired. If Iceberg Physical Input is still huge, partition pruning failed.
- Zero but `dynamicFilters = {...}` visible in the plan? The dynamic filter timed out. **Action: increase `dynamic-filtering.wait-timeout` for JDBC to 45-60 seconds in `etc/catalog/app_pg.properties`:**

```properties
dynamic-filtering.wait-timeout = 45s
```

**2. Look at PostgreSQL Physical Input vs. expected rows:**
- Physical Input ≈ full table? Predicate pushdown failed. Check whether the column is VARCHAR — VARCHAR predicates do NOT push down on the PostgreSQL connector. Workaround: add a numeric/date filter alongside the VARCHAR filter.
- Physical Input ≈ expected rows? Pushdown succeeded; PostgreSQL is not the bottleneck.

**3. Compare wall times across operators:**
- PostgreSQL: 25s, Iceberg: 3s → **PostgreSQL bottleneck.** Increase `defaultRowFetchSize` in the PostgreSQL JDBC URL (try 1000 or 5000). Check whether the PostgreSQL replica CPU is saturated. Add an index to the WHERE columns.
- PostgreSQL: 2s, Iceberg: 30s → **Iceberg bottleneck.** Physical Input on Iceberg is high, DF is not firing. Recheck partition pruning and the dynamic filter wait-timeout.
- PostgreSQL: 8s, Iceberg: 8s, Join: 15s → **Join bottleneck.** Use `SET SESSION join_distribution_type = 'BROADCAST'` for small dimensions to ensure the smaller table is the build side.

### Practical Immediate Actions

1. Run `EXPLAIN ANALYZE VERBOSE` once to get ground-truth numbers.
2. Check PostgreSQL `Physical Input`. If ≈ full table, add a pushable date/numeric filter alongside any VARCHAR filter.
3. Check `dynamicFilterSplitsProcessed` on Iceberg. If zero, raise `dynamic-filtering.wait-timeout` to 45s in `etc/catalog/app_pg.properties`.
4. If Iceberg Physical Input is large, verify your `WHERE event_time >= ...` is partition-aligned (no function wrapping like `date_trunc()`).
5. Use the Trino Web UI `/ui/` for a visual breakdown — the per-query timeline makes the slow operator obvious at a glance.
