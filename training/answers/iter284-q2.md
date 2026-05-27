# Iter284 Q2 — system.query() Passthrough for JSONB GIN Index Filtering

## Answer

Yes, `system.query()` is a real Trino table function that sends raw SQL verbatim to Postgres. It's the right tool when you need Postgres-specific JSONB operators that Trino doesn't speak — your GIN index gets used because the filter runs entirely on the Postgres side.

## Why JSONB filters are slow through standard Trino queries

Trino's JSON functions (`json_extract_scalar`, `json_extract`) run on Trino workers, not on Postgres. A query like:

```sql
WHERE json_extract_scalar(config, '$.tier') = 'enterprise'
```

causes Trino to fetch the entire `customers` table over JDBC, then evaluate the function in Trino memory. Postgres never sees the filter — the GIN index is ignored entirely.

## How system.query() works

The PostgreSQL connector exposes `<catalog>.system.query()` as a table function. It takes a `query =>` named parameter containing a raw Postgres SQL string, sends it to Postgres verbatim over JDBC, and returns the result as a Trino table:

```sql
SELECT * FROM TABLE(
  app_pg.system.query(
    query => 'SELECT customer_id, config FROM customers WHERE config @> ''{"tier": "enterprise"}'''
  )
);
```

The `@>` operator is native Postgres JSONB — Postgres executes it, the GIN index fires, and only matching rows come back over JDBC.

**Single-quote doubling**: Inside the `query =>` string, single quotes must be doubled (`''`). `'{"tier": "enterprise"}'` becomes `''{"tier": "enterprise"}''` inside the outer SQL string.

## Critical gotcha: no outer predicate pushdown

Once `system.query()` returns rows to Trino, you cannot push additional filters back to Postgres. A WHERE clause outside the function runs in Trino memory on the full result:

```sql
-- SLOW — Postgres returns all rows; Trino filters in memory
SELECT * FROM TABLE(
  app_pg.system.query(query => 'SELECT customer_id, config FROM customers')
) WHERE config @> '{"tier": "enterprise"}';

-- FAST — filter is inside the Postgres SQL; GIN index used
SELECT * FROM TABLE(
  app_pg.system.query(
    query => 'SELECT customer_id, config FROM customers WHERE config @> ''{"tier": "enterprise"}'''
  )
);
```

Put ALL filtering logic inside the `query =>` string. Anything outside becomes a residual in-memory filter on the full returned result set.

## Joining with Iceberg tables — yes, this works

The result of `system.query()` is just a Trino table — you can join it against Iceberg tables normally. The join runs on Trino workers:

```sql
SELECT c.customer_id, c.config, COUNT(e.event_id) AS event_count
FROM TABLE(
  app_pg.system.query(
    query => 'SELECT customer_id, config FROM customers WHERE config ? ''tier'''
  )
) AS c
INNER JOIN iceberg.analytics.events e
  ON c.customer_id = e.customer_id
WHERE e.event_date >= CURRENT_DATE - INTERVAL '30' DAY
GROUP BY c.customer_id, c.config;
```

Dynamic filtering also applies: Trino derives an IN-list of matching `customer_id` values from the Postgres result and pushes it into the Iceberg scan to prune files before the join executes. This is on by default and makes the join efficient.

## ORDER BY inside system.query() is NOT preserved

If you write `ORDER BY` inside the `query =>` string, Trino does not guarantee that order is preserved in the final result. Trino may distribute rows across workers in any order. Apply ORDER BY outside the function, at the Trino level, if you need ordered results.

## Security note for your OPA setup

`system.query()` sends SQL verbatim to Postgres — Trino's query analysis and OPA authorization run on the raw Trino call, not on what's inside the string. OPA row-level filters and column masks that Trino applies to normal Postgres table scans do NOT apply to `system.query()` results. In a multi-tenant setup where OPA enforces tenant isolation, a user who can call `system.query()` could potentially bypass those filters. Restrict access to the function via OPA policy if this is a concern.

## Before reaching for system.query()

Standard Trino predicate pushdown does work for simple JSONB equality:

```sql
-- Simple equality — MAY push down to Postgres
SELECT customer_id, config FROM app_pg.public.customers
WHERE config = CAST('{"tier": "enterprise"}' AS JSON);
```

Run `EXPLAIN (TYPE DISTRIBUTED)` on this first. If you see a `constraint on [config]` block under the `TableScan` node with no `ScanFilterProject` above it, the filter pushed and the GIN index may fire. Use `system.query()` when you need Postgres-specific operators (`@>`, `?`, `->`, `#>>`) that have no direct Trino equivalent.

## Quick reference

| Scenario | Approach |
|---|---|
| Simple JSONB equality | Try standard Trino query; verify with EXPLAIN |
| Postgres-specific operators (`@>`, `?`, `->`) | Use `system.query()` with filter inside the string |
| ORDER BY on result | Apply ORDER BY at Trino level, not inside string |
| JOIN with Iceberg | Works — join executes on Trino with DF on Iceberg side |
| OPA row filters | Do NOT apply inside system.query() — restrict access if needed |
