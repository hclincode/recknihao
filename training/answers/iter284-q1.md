# Iter284 Q1 — Verifying Predicate Pushdown to Postgres via EXPLAIN ANALYZE

## Answer

The canonical way to verify predicate pushdown is to run `EXPLAIN (TYPE DISTRIBUTED)` first — it shows the plan without executing the query. Then escalate to `EXPLAIN ANALYZE` only if you need runtime row count confirmation.

## The key structural signal: ScanFilterProject above TableScan

Pushdown works or fails based on the **position of your filter in the plan tree**, not any specific keyword.

**Pushdown SUCCEEDED** — filter appears inside the TableScan as a `constraint`:

```
TableScan[table = app_pg:public.accounts, ...]
    Layout: [id, status, ...]
    constraint on [status]
        status = 'active'
```

There is NO `ScanFilterProject` or `Filter` node above the `TableScan`. The constraint is embedded — Postgres receives `WHERE status = 'active'` and can use its index.

**Pushdown FAILED** — a separate filter node sits above the scan:

```
ScanFilterProject[filterPredicate = (status = 'active')]
    TableScan[table = app_pg:public.accounts, ...]
        Layout: [id, status, ...]
        (no constraint block)
```

The `ScanFilterProject` above the `TableScan` means Trino fetched all rows from Postgres and filtered in-memory. The `TableScan` has no `constraint` block — Postgres received a bare `SELECT *`.

## Running the EXPLAIN

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT e.event_id, e.occurred_at, a.plan_type
FROM iceberg.analytics.events e
JOIN app_pg.public.accounts a ON e.account_id = a.id
WHERE a.status = 'active'
  AND e.occurred_at >= TIMESTAMP '2026-05-01 00:00:00';
```

Scan the output for the Postgres `TableScan` node. If your filter (`a.status = 'active'`) appears in a `constraint on [status]` block under it: pushdown succeeded. If it appears in a `ScanFilterProject` above it: pushdown failed.

## Runtime confirmation with EXPLAIN ANALYZE

If you need actual row counts:

```sql
EXPLAIN ANALYZE
SELECT e.event_id, e.occurred_at, a.plan_type
FROM iceberg.analytics.events e
JOIN app_pg.public.accounts a ON e.account_id = a.id
WHERE a.status = 'active';
```

On the Postgres `TableScan` node, look at:
- **`Input: N rows`** — the number of rows Trino actually received from Postgres
- If the table has 5M rows but `Input` shows 50K, Postgres applied the filter server-side — pushdown worked
- If `Input` shows 5M rows and a `ScanFilterProject` above it shows `Output: 50K rows`, Trino fetched everything and filtered in-memory — pushdown failed

## For your federated join specifically

Both sides have their own pushdown behavior:

**Postgres side**: Check that your `WHERE a.status = 'active'` appears in the `constraint on` block under the Postgres `TableScan`.

**Iceberg side**: Check that your timestamp predicate (`e.occurred_at >= ...`) appears as a partition constraint on the Iceberg `TableScan`. If your Iceberg table is partitioned by `day(occurred_at)` or `month(occurred_at)`, your WHERE clause must use the raw column (not wrapped in a function) for file pruning to kick in.

**Dynamic filtering**: Look for a `dynamicFilters = {...}` annotation on the Iceberg `TableScan`. In `EXPLAIN ANALYZE`, `dynamicFilterSplitsProcessed > 0` confirms that DF fired — meaning Trino derived an IN-list of matching account IDs from the Postgres side and pushed it into the Iceberg scan to prune files before the join.

## Ground truth: Postgres slow query log

The most definitive check is enabling slow query logging on your Postgres replica:

```sql
-- On the replica (or in postgresql.conf):
SET log_min_duration_statement = 0;  -- log all queries
```

If the SQL Trino sends to Postgres includes your WHERE clause (`WHERE status = 'active'`), pushdown worked and the index was available. If it's a bare `SELECT id, status FROM accounts`, pushdown failed.

## Common reasons pushdown fails

- **Function wrapping**: `WHERE LOWER(a.status) = 'active'` — wrapping the column in a function prevents pushdown; use `WHERE a.status = 'active'` instead
- **Type mismatch**: comparing a Postgres `varchar` column against a Trino `integer` literal breaks pushdown
- **OR conditions spanning multiple tables**: a filter like `WHERE a.status = 'active' OR e.event_type = 'signup'` can't push to Postgres because half of it references Iceberg
- **ILIKE on varchar**: case-insensitive string match requires `enable_string_pushdown_with_collate=true` as a session property and compatible column collation — without this, ILIKE stays in Trino
