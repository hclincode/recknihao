# Iter265 Q1 — Reading Trino EXPLAIN for a Postgres+Iceberg Federated Query

## Answer

There are two specific things you asked about. Let me address both directly.

### Part 1: Did Your WHERE Clause Run on Postgres or on Trino?

Run `EXPLAIN (TYPE DISTRIBUTED)` first — this is free, it doesn't execute the query:

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT ...
FROM postgres_table JOIN iceberg_table ON ...
WHERE postgres_column = 'value';
```

**The answer is determined by the vertical position in the plan tree:**

**Pushdown SUCCEEDED** (Postgres ran your WHERE clause server-side):
```
TableScan[table = app_pg:public.orders, ...]
    constraint on [order_date]
        order_date >= '2026-01-01'
```
- The predicate appears INSIDE the `TableScan` as a `constraint on [column]` line
- NO separate `ScanFilterProject` or `Filter` node above the `TableScan`
- Postgres applied the filter and returned only matching rows over JDBC

**Pushdown FAILED** (Trino pulled all rows and filtered in-memory):
```
ScanFilterProject[filterPredicate = (postgres_column = 'value')]
    └─ TableScan[table = app_pg:public.orders, ...]
```
- A `ScanFilterProject` or `Filter` node sits ABOVE the `TableScan`
- The `TableScan` itself has no `constraint on` for that predicate
- Postgres returned ALL rows unfiltered, and Trino workers filtered them after the JDBC fetch

**The key signal: vertical position.** Predicate inside the TableScan = pushed. Predicate in a node above the TableScan = NOT pushed.

### Part 2: Which Step Is Taking the Longest?

Run `EXPLAIN ANALYZE` once you know the plan structure (warning: this actually executes the full query):

```sql
EXPLAIN ANALYZE
SELECT ...
FROM postgres_table JOIN iceberg_table ON ...
WHERE postgres_column = 'value';
```

On each operator node, look for these runtime fields:

**On the Postgres `TableScan` operator:**

1. **`Input: N rows (size)` vs `Output: N rows`** — the most direct signal.
   - If `Input: 5,200,000 rows (450MB)` but your final result is only 200K rows → Postgres sent the entire table unfiltered, and Trino filtered 95% of the rows locally. That's failure.
   - If `Input: 52,000 rows (4.51MB)` and your final result is similar → pushdown worked, Postgres filtered server-side.

2. **`Physical Input: XXX MB`** — total bytes received from Postgres over JDBC. Large value relative to your expected result = predicates didn't push, Trino fetched more data than necessary.

3. **`Wall: X.XXs`** — real clock time the operator spent. Compare this against the join operator's Wall time to see where time is actually going.

**Example bottleneck diagnosis:**
```
TableScan[app_pg:public.orders]
    Input: 5200000 rows (450MB)     ← Postgres sent everything unfiltered
    Wall: 8.20s                     ← Scan is the bottleneck

InnerJoin[...][PARTITIONED]
    Wall: 2.15s                     ← Join is much faster
```

Here the Postgres scan is 4× slower than the join — the bottleneck is predicate pushdown failure on the Postgres side. Fix the WHERE clause (use a date or numeric column that pushes reliably) and the scan time will drop dramatically.

### What the Other Terms Mean

- **`InnerJoin` / `HashJoin`** — the join operator. Trino builds a hash table from one side and probes with the other. If this is slow, the join itself (not the scan) is the bottleneck.
- **`RemoteExchange`** — data shuffling between Trino workers. High wall time here means a lot of data is being moved between workers, usually because the join is large.
- **`ScanFilterProject`** — combined scan + filter + projection operator. The `Filter` part tells you a WHERE clause was NOT pushed down and is running on Trino workers.

### The Complete Two-Step Workflow

1. **`EXPLAIN (TYPE DISTRIBUTED)`** — instant, free. Look for `ScanFilterProject` above `TableScan` (failure) vs `constraint on` inside `TableScan` (success). Tells you your plan structure.

2. **`EXPLAIN ANALYZE`** — executes the query, adds runtime stats. Check `Input:` row count and `Wall:` time on each operator. The operator with the largest `Input:` rows or largest `Wall:` time is your bottleneck.

### Important: VARCHAR Predicates Often Don't Push

If your WHERE clause is on a text column (`WHERE status = 'active'`), it may not push to Postgres. The PostgreSQL connector is conservative with string predicates due to collation rules. The most reliable predicates to push are numeric comparisons, date ranges, and IS NULL/IS NOT NULL. If you must filter on VARCHAR, pair it with a date or numeric predicate that DOES push — Postgres will reduce rows on the server side, and Trino will apply the VARCHAR filter to the smaller result set.
