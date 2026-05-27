# Iter287 Q2 — Postgres Array Column Mapping in Trino

## Answer

Yes, Trino can work with Postgres `TEXT[]` columns, but only after enabling array mapping. The default configuration silently drops array columns with no error — which is why the column disappears.

## Why the column is missing

The default setting is `postgresql.array-mapping=DISABLED` in `etc/catalog/app_pg.properties`. With this default, array-type columns are silently dropped from Trino's schema view. The column won't appear in `DESCRIBE`, `SELECT *`, or any query result. No error is thrown — it just vanishes, the same behavior as `unsupported-type-handling=IGNORE` for other unsupported types.

Confirm by comparing:
```sql
DESCRIBE app_pg.public.customers;  -- tags column absent
```
vs. `\d public.customers` in Postgres — if `tags` shows there but not in Trino, `array-mapping=DISABLED` is the cause.

## The fix: enable array mapping

In `etc/catalog/app_pg.properties`:

```properties
connector.name=postgresql
connection-url=jdbc:postgresql://app-postgres-replica.app.svc.cluster.local:5432/appdb
connection-user=${ENV:APP_PG_USER}
connection-password=${ENV:APP_PG_PASSWORD}

postgresql.array-mapping=AS_ARRAY
```

Restart coordinator and workers. The `TEXT[]` column now maps to Trino's `ARRAY<VARCHAR>` type.

## Filtering inside the array

Once visible as `ARRAY<VARCHAR>`, you can filter using Trino array functions:

```sql
-- Customers where tags contains 'enterprise'
SELECT customer_id, tags
FROM app_pg.public.customers
WHERE CONTAINS(tags, 'enterprise');

-- Customers where tags contains 'enterprise' OR 'vip'
SELECT customer_id, tags
FROM app_pg.public.customers
WHERE ANY_MATCH(tags, x -> x = 'enterprise' OR x = 'vip');

-- Get the first tag
SELECT customer_id, ELEMENT_AT(tags, 1) AS first_tag
FROM app_pg.public.customers;
```

## Array mapping options

| Setting | What you get | When to use |
|---|---|---|
| `DISABLED` (default) | Column silently dropped | Never — unless you explicitly don't want array columns |
| `AS_ARRAY` | `ARRAY<VARCHAR>` for `TEXT[]`; `ARRAY<INTEGER>` for `INTEGER[]`, etc. | Recommended — fully typed, all Trino array functions work |
| `AS_JSON` | Entire array as Trino `JSON` string (e.g. `["enterprise","vip"]`) | Multi-dimensional arrays only — OSS Trino's ARRAY type is flat, so `TEXT[][]` needs JSON |

For your `TEXT[]` tags column, `AS_ARRAY` is the right choice.

## Session-level test (no restart)

```sql
SET SESSION app_pg.array_mapping = 'AS_ARRAY';
SELECT customer_id, tags FROM app_pg.public.customers WHERE CONTAINS(tags, 'enterprise');
```

## Critical caveat: array predicates don't push down to Postgres

The `CONTAINS(tags, 'enterprise')` filter runs on Trino workers — it does NOT push down to Postgres. Trino fetches all rows over JDBC, then evaluates the filter in memory. For large customer tables this is slow.

If you need to use Postgres's native `@>` operator (which CAN use a GIN index), use `system.query()` passthrough:

```sql
SELECT * FROM TABLE(
  app_pg.system.query(
    query => 'SELECT customer_id, tags FROM customers WHERE tags @> ARRAY[''enterprise'']'
  )
);
```

This sends the query verbatim to Postgres, the GIN index fires. You can still JOIN the result against Iceberg tables in the same Trino query.

For heavy analytics on tags, the best long-term pattern is to denormalize into Iceberg during ingestion — one row per customer-tag pair — so filtering becomes a simple Iceberg predicate with columnar pushdown.
