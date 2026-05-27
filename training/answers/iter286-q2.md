# Iter286 Q2 — ILIKE Pushdown to Postgres via Trino

## Answer

ILIKE does NOT push down to Postgres by default — Trino pulls all rows over JDBC and applies the case-insensitive filter in Trino worker memory. Your Postgres index is not used.

## Default behavior (no pushdown)

```sql
-- This does NOT push down by default in Trino 467
SELECT * FROM app_pg.public.customers WHERE name ILIKE 'acme%';
```

Trino fetches the entire `customers` table over JDBC, then applies `ILIKE 'acme%'` in memory. Confirm with:

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT * FROM app_pg.public.customers WHERE name ILIKE 'acme%';
```

**Pushdown FAILED** (the default):
```
ScanFilterProject[filterPredicate = (name ILIKE 'acme%')]
    TableScan[table = app_pg:public.customers]
```
The `ScanFilterProject` above `TableScan` means Trino is filtering in-memory after fetching all rows.

## Enabling ILIKE pushdown (experimental, with caveats)

There is a session property that enables pushdown for string predicates including ILIKE:

```sql
SET SESSION app_pg.enable_string_pushdown_with_collate = true;
```

With this enabled, Trino will attempt to push ILIKE down to Postgres by appending `COLLATE "C"` to the predicate. This makes string comparison byte-ordered rather than locale-aware.

**Two conditions must both be met for this to work correctly:**
1. The session property is enabled (`false` by default)
2. The Postgres column uses a C/POSIX/standard UTF-8 collation — if the column uses a custom or ICU-based collation, pushing `COLLATE "C"` can return different results than Trino's in-memory evaluation (a correctness bug)

**Concrete test:**
```sql
SET SESSION app_pg.enable_string_pushdown_with_collate = true;
EXPLAIN (TYPE DISTRIBUTED)
SELECT * FROM app_pg.public.customers WHERE name ILIKE 'acme%';
```

Check: does `ScanFilterProject` disappear from above the `TableScan`? If yes, pushdown is working. Verify with `EXPLAIN ANALYZE` that the Postgres `TableScan` `Input: N rows` is selective (much smaller than total table rows).

## Production-safe alternative: lowercase generated column

For guaranteed index usage regardless of session flags and collation details, add a generated column on Postgres:

```sql
-- One-time setup on your Postgres replica:
ALTER TABLE customers
  ADD COLUMN lower_name TEXT GENERATED ALWAYS AS (lower(name)) STORED;
CREATE INDEX idx_customers_lower_name ON customers (lower_name);
```

Then query through Trino using equality on the generated column (equality always pushes down):

```sql
SELECT c.id, c.name, e.event_type
FROM app_pg.public.customers c
JOIN iceberg.analytics.events e ON c.id = e.customer_id
WHERE c.lower_name = lower('Acme Corp');  -- lower() applied at query time
-- OR for prefix search:
WHERE c.lower_name LIKE 'acme%';  -- standard LIKE on lower_name pushes via normal string pushdown
```

This approach:
- Always pushes to Postgres and uses the index — no session flags, no collation concerns
- Deterministically correct across all Postgres locales
- Requires only a one-time schema change on the read replica

## Quick reference

| Approach | ILIKE pushes? | Index used? | Caveats |
|---|---|---|---|
| Default (no flag) | No | No | Full table JDBC fetch every query |
| `enable_string_pushdown_with_collate=true` | Yes (if collation compatible) | Yes (if compatible) | Experimental; COLLATE "C" correctness risk on non-standard collations |
| Lowercase generated column + LIKE | Yes (via standard pushdown) | Yes | One-time schema change on Postgres |

For your on-prem production stack, the generated column pattern is the safest path. Test the experimental session flag on your non-prod Postgres replica first before enabling it cluster-wide.
