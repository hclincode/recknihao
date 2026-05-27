# Iter254 Q1 — Predicate Pushdown Verification and LIKE Filter Behavior

## Answer

Your concern is real and important. Yes, Trino can push certain filters down to Postgres so Postgres returns only matching rows — but LIKE patterns are a special case. Here is how to tell which is happening and what to expect.

## The Two Paths — Network Traffic Matters

When you write `WHERE customer_id = 123` in a Trino query against Postgres:

1. **Pushdown SUCCEEDED** (the good case): Trino sends `SELECT ... FROM users WHERE customer_id = 123` to Postgres. Postgres filters on the server and returns 1 row over the network.

2. **Pushdown FAILED** (the bad case): Trino sends `SELECT ... FROM users` with NO WHERE clause. Postgres returns all 1 million rows. Trino workers then filter in-memory. All 1 million rows crossed the network.

The performance difference is enormous.

## What Pushes Down to Postgres By Default

| Predicate type | Example | Pushes down? |
|---|---|---|
| Equality on VARCHAR | `WHERE name = 'acme'` | **YES** |
| IN list on VARCHAR | `WHERE status IN ('active', 'pending')` | **YES** |
| IS NULL / IS NOT NULL on VARCHAR | `WHERE email IS NOT NULL` | **YES** |
| Equality on numeric/date | `WHERE customer_id = 123` | **YES** |
| Anchored LIKE (starts-with) | `WHERE name LIKE 'acme%'` | **MAYBE** — verify with EXPLAIN |
| Non-anchored LIKE (contains) | `WHERE name LIKE '%acme%'` | **NO** |
| Non-anchored LIKE (ends-with) | `WHERE name LIKE '%acme'` | **NO** |
| ILIKE (case-insensitive) | `WHERE name ILIKE 'ACME%'` | **NO** |
| String range predicates | `WHERE name > 'M'` | **NO** (by default; see enable_string_pushdown_with_collate) |

**The core rule for LIKE**: Anchored patterns (`'foo%'`) may push to Postgres because they can use a B-tree index scan. Non-anchored patterns (`'%foo%'`, `'%foo'`) require full scans and are never pushed. ILIKE never pushes.

## How to Check If Your Filter Actually Reached Postgres

### Method 1: EXPLAIN (TYPE DISTRIBUTED) — Fast, No Query Execution

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT * FROM app_pg.public.customers
WHERE customer_id = 123 AND name LIKE 'acme%';
```

**Pushdown SUCCEEDED** — predicate appears inside the `TableScan` constraint:

```
TableScan[table=app_pg:public.customers, constraint=(customer_id = 123 AND name LIKE 'acme%')]
```

The predicate has disappeared from the plan tree above the scan. There is no separate `Filter` node. Postgres is handling it server-side.

**Pushdown FAILED** — a separate `Filter` or `ScanFilterProject` node sits ABOVE the `TableScan`:

```
ScanFilterProject[filter=(name LIKE '%acme%')]
    TableScan[table=app_pg:public.customers, constraint=(customer_id = 123)]
```

Here `customer_id = 123` pushed to Postgres but `LIKE '%acme%'` did not — Trino is filtering it in-memory after fetching all matching rows.

**Visual rule**: predicate **inside** the TableScan constraint = pushed to Postgres. Predicate **in a separate node above** the TableScan = not pushed, Trino filters.

### Method 2: EXPLAIN ANALYZE — Shows Actual Row Counts

This executes the query, so use it only when you know the query is safe to run:

```sql
EXPLAIN ANALYZE SELECT * FROM app_pg.public.customers WHERE customer_id = 123;
```

Look at the `Input:` field on the `TableScan` node — this is the number of rows Postgres actually returned to Trino.

- `Input: 1` (or a small number matching your filter) → Postgres filtered; pushdown succeeded
- `Input: 1000000` (the full table) → Postgres returned everything; Trino filtered; pushdown failed

### Method 3: pg_stat_activity on Postgres Replica — Real-Time Observation

While your Trino query is running (from another session on the replica):

```sql
SELECT pid, usename, query, state
FROM pg_stat_activity
WHERE usename = 'trino_reader'
ORDER BY query_start DESC;
```

The `query` column shows the SQL Trino sent to Postgres. If it contains your WHERE clause, pushdown succeeded. If there is no WHERE clause, Trino is filtering in-memory.

### Method 4: Postgres Slow Log — Definitive Ground Truth

Enable slow-query logging on your Postgres read replica (requires superuser):

```sql
ALTER SYSTEM SET log_min_duration_statement = 0;  -- log all queries
SELECT pg_reload_conf();
```

Then run your Trino query and check the Postgres log. The actual SQL Postgres received is authoritative — cannot be misread like EXPLAIN sometimes can be.

After checking, disable logging to avoid log volume:

```sql
ALTER SYSTEM SET log_min_duration_statement = -1;
SELECT pg_reload_conf();
```

## LIKE Behavior Details — Your Specific Question

**`LIKE 'acme%'` (starts-with)**: This may push to Postgres on standard-collation VARCHAR columns because Postgres can use a B-tree index scan for this pattern. However, push behavior is collation-dependent — if your column has a non-default collation, it may not push even for anchored patterns. **Always verify with EXPLAIN for your specific column.**

**`LIKE '%acme%'` (contains anywhere)**: This will **NOT** push to Postgres. Trino fetches all rows from Postgres matching any other pushed predicates, then filters the `LIKE` condition itself. If the column is indexed in Postgres, that index is ignored entirely.

**`ILIKE 'Acme%'` (case-insensitive)**: This will **NOT** push, regardless of pattern type. Always filters in Trino.

## If the Filter Won't Push: Options

**Option 1: Use `system.query()` to hand the SQL directly to Postgres**

```sql
SELECT * FROM TABLE(
  app_pg.system.query(
    query => 'SELECT * FROM customers WHERE customer_id = 123 AND name LIKE ''%acme%'''
  )
);
```

This bypasses Trino's pushdown logic entirely and runs the SQL on Postgres directly. Postgres uses its own indexes and returns only matching rows. Useful for complex predicates that Trino won't push.

**Option 2: Filter in two steps**

If you have a more selective pushed predicate (like `customer_id`), let that push first to reduce the rows Trino has to filter with the non-pushable LIKE:

```sql
SELECT * FROM app_pg.public.customers
WHERE customer_id BETWEEN 100 AND 200    -- this pushes to Postgres
  AND name LIKE '%acme%';               -- this filters in Trino, but on a small result set
```

**Option 3: Consider `enable_string_pushdown_with_collate` session property** (experimental)

```sql
SET SESSION app_pg.enable_string_pushdown_with_collate = true;
```

This enables range predicates (`>`, `<`, `BETWEEN`) on VARCHAR columns to push down. Does NOT affect LIKE (already pushes for simple anchored patterns) or ILIKE (never pushes). Use with caution and verify with EXPLAIN first — collation mismatches can produce wrong results.

## TL;DR

- **Equality and IN on VARCHAR** (`=`, `IN`) → always push to Postgres
- **Anchored LIKE** (`'foo%'`) → verify with EXPLAIN; may or may not push
- **Non-anchored LIKE** (`'%foo%'`) → never pushes; Trino filters in-memory
- **ILIKE** → never pushes
- **To verify**: run `EXPLAIN (TYPE DISTRIBUTED)` and look for the constraint inside the TableScan node; or check `pg_stat_activity` on the replica while the query runs
- **To force pushdown of complex predicates**: use `system.query()` to run native Postgres SQL
