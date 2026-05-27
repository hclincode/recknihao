# Iter 173 Q1 — Reading EXPLAIN ANALYZE to Verify PostgreSQL Pushdown at Runtime

## Answer

Here's how to read `EXPLAIN ANALYZE` output to tell whether Postgres actually did the filtering, versus Trino pulling everything and filtering locally.

### (1) EXPLAIN vs EXPLAIN ANALYZE

**`EXPLAIN (TYPE DISTRIBUTED)`** shows the planning-time view without executing the query — cheap and safe to run repeatedly.

**`EXPLAIN ANALYZE`** actually runs the query and collects runtime statistics per operator. Same cost as the query itself. Use this after EXPLAIN says pushdown should happen, but the query is still slow.

The key advantage of ANALYZE: it shows what **actually happened at runtime**, not just what the planner intended.

### (2) Specific Runtime Fields to Look For in EXPLAIN ANALYZE

When you run `EXPLAIN ANALYZE` on a Postgres-backed scan, look for these on the **TableScan node**:

| Field | What it tells you | Detecting failed pushdown |
|---|---|---|
| **Physical Input** | Total bytes read from Postgres over JDBC | If ≈ your full table size in bytes, pushdown failed — Trino fetched the entire table |
| **Input rows** | Rows returned by the Postgres scan | Compare against the table's total row count. If ≈ total rows, the scan was unfiltered |
| **CPU / Elapsed / Scheduled** | Time on the TableScan node | High elapsed relative to overall query = Postgres scan is the bottleneck |

**The most concrete signal**: compare `Input rows` on the Postgres TableScan against your table's total row count.

Example: your query ultimately returned 1,000 rows, but `Input rows` shows 5,200,000 — Trino fetched the entire table from Postgres and filtered 5.2M rows locally. That is the **unambiguous signature of failed predicate pushdown**.

### (3) What the Plan Looks Like When Filtering Happened on Postgres vs Locally

**Pushdown SUCCEEDED** — the predicate appears inside the `TableScan`'s `constraint on` block, NO filter node above:

```
TableScan[table = app_pg:public.orders, ...]
    Layout: [id, order_date, status, amount]
    constraint on [status, order_date]
        status = 'active'
        order_date >= DATE '2026-05-01'
```

`constraint on [columns]` lines tell you the predicate was embedded inside the scan. Postgres applied the filter server-side and returned only matching rows. No ScanFilterProject above = success.

**Pushdown FAILED** — a `ScanFilterProject` or `Filter` node sits ABOVE the `TableScan`:

```
ScanFilterProject[filterPredicate = (status = 'active') AND (order_date >= DATE '2026-05-01')]
    TableScan[table = app_pg:public.orders]
        Layout: [id, order_date, status, amount]
```

Postgres returned unfiltered rows; Trino workers applied the filter in-memory after fetching everything. The slow path.

**The rule**: if the predicate is inside the `constraint on` block under TableScan, pushdown succeeded. If it's in a Filter/ScanFilterProject node ABOVE the scan, pushdown failed.

**Note on output format**: `EXPLAIN (TYPE DISTRIBUTED)` shows a simplified one-liner in teaching diagrams. Real Trino 467 output uses a multi-line tree — the `constraint on [columns]` entries appear as separate indented lines under the TableScan node. The signal is the same; just look for `constraint on` anywhere under the TableScan.

### (4) Verify with pg_stat_activity on Postgres

This is the ground truth. While reading EXPLAIN output, the **actual SQL Postgres received is the definitive proof**:

```sql
-- On the Postgres replica:
SELECT usename, application_name, query, state
FROM pg_stat_activity
WHERE usename = 'trino_reader';
```

If pushdown succeeded: `SELECT id, order_date, status, amount FROM orders WHERE status = 'active' AND order_date >= DATE '2026-05-01'`

If pushdown failed: `SELECT id, order_date, status, amount FROM orders` — no WHERE clause, Trino filtered locally.

### (5) Common Reasons Why EXPLAIN Says Pushdown Should Work But the Query Is Still Slow

**A. Missing index on Postgres**
Pushdown happened (WHERE clause sent to Postgres) but Postgres doesn't have an index on the filter columns. Postgres does a full sequential scan even with the WHERE clause.

Detect: run `EXPLAIN (ANALYZE)` directly on Postgres replica with the same WHERE — look for `Seq Scan` vs `Index Scan`.

Fix: `CREATE INDEX CONCURRENTLY ON orders(status, order_date);`

**B. Large result set even after filtering**
Pushdown succeeded AND the index works, but your filter matches millions of rows. Returning 5M rows over JDBC to Trino is slow — pure network overhead.

Detect: `Input rows` in EXPLAIN ANALYZE is in the millions even after filtering.

Fix: add more selective predicates (`AND tenant_id = '...'`, `AND created_at > ...`), or pre-aggregate on the Postgres side.

**C. Cache miss on Postgres**
Index exists but data/index pages aren't in Postgres buffer pool. First query after a restart is always slow.

Detect: run the query twice — second run is dramatically faster.

**D. Network latency or connection overhead**
OSS Trino 467 has no native connection pooling — each worker opens a fresh JDBC connection. Under load this creates many concurrent TCP streams.

Fix: put PgBouncer between Trino and Postgres in transaction-pooling mode, and tune `defaultRowFetchSize=1000` in the JDBC URL to reduce round-trips.

**E. Dynamic filtering didn't fire at runtime**
EXPLAIN plan shows `dynamicFilters` wired up, but at runtime the filter arrived too late or not at all.

Detect: in EXPLAIN ANALYZE output, look for `dynamicFilterSplitsProcessed` on the probe-side scan. If it's 0 or absent, dynamic filtering didn't fire.

### Concrete Debugging Workflow

1. `EXPLAIN (TYPE DISTRIBUTED)` — check for `constraint on [...]` inside TableScan vs filter node above.
2. `EXPLAIN ANALYZE` — look at `Physical Input` and `Input rows` on the TableScan. Compare against full table size.
3. Check `pg_stat_activity` — look at the actual SQL Postgres received. If no WHERE clause, pushdown failed at JDBC layer.
4. If WHERE clause is there but still slow — run `EXPLAIN ANALYZE` on Postgres directly to check for Seq Scan vs Index Scan.
5. If index exists and Postgres is fast — it's network/connection overhead. Tune `defaultRowFetchSize` and consider PgBouncer.
