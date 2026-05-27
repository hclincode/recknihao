# Iter263 Q1 — Predicate Pushdown Debugging: Is My WHERE Clause Running on Postgres or Trino?

## Answer

The short answer: **your date range filter `WHERE created_at >= '2026-01-01'` IS very likely pushing down to Postgres**, because date and timestamp comparisons are among the most reliable predicates to push. But here's how to verify for certain, and what to do if something else in your query is blocking the pushdown.

### Step 1: Use EXPLAIN to See the Plan Structure

Run this first — it's fast and doesn't execute the query:

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT *
FROM app_pg.public.orders
WHERE created_at >= '2026-01-01';
```

Look at the output carefully. You're looking for one of two signatures:

**Pushdown SUCCEEDED** (what you want):
```
TableScan[table = app_pg:public.orders, ...]
    Layout: [id, created_at, ...]
    constraint on [created_at]
        created_at >= '2026-01-01'
```

If you see `constraint on [created_at]` **below** the TableScan node, your predicate is embedded in the scan itself — PostgreSQL is applying the filter server-side.

**Pushdown FAILED** (the slow path):
```
ScanFilterProject[filterPredicate=(created_at >= '2026-01-01')]
    └─ TableScan[table = app_pg:public.orders, ...]
        Layout: [id, created_at, ...]
```

If you see a `ScanFilterProject` or `Filter` node **above** the TableScan, Trino is fetching unfiltered rows from Postgres and filtering them in-memory on Trino workers.

**Critical rule:** If you see `ScanFilterProject` or `Filter` above the TableScan, pushdown failed. If the predicate is embedded in a `constraint on` block under the TableScan, pushdown succeeded.

### Step 2: Verify at Runtime with EXPLAIN ANALYZE

Once you've confirmed the plan structure, run `EXPLAIN ANALYZE` to see actual row counts:

```sql
EXPLAIN ANALYZE
SELECT *
FROM app_pg.public.orders
WHERE created_at >= '2026-01-01';
```

Look for the `Input:` and `Output:` row counts on the TableScan operator:

```
TableScan[table = app_pg:public.orders, ...]
    Input: 52000 rows (4.51MB)
    Output: 52000 rows
    constraint on [created_at]
        created_at >= '2026-01-01'
```

**The `Input: 52000 rows` is the proof.** If your `orders` table has 5 million total rows but Postgres returned only 52,000 rows, Postgres applied the date filter server-side. If `Input: 5200000 rows (450MB)` — that's the whole table coming over JDBC.

### Step 3: Check PostgreSQL Directly (Ground Truth)

Query `pg_stat_activity` while the Trino query is running:

```sql
-- On the Postgres replica, while the Trino query executes:
SELECT query FROM pg_stat_activity 
WHERE state = 'active' 
  AND query LIKE '%orders%';
```

**Pushdown succeeded** — Postgres received the WHERE clause:
```sql
SELECT ... FROM orders WHERE created_at >= '2026-01-01';
```

**Pushdown failed** — Postgres received an unfiltered query:
```sql
SELECT ... FROM orders;  -- no WHERE clause
```

This is the **definitive check**. The SQL that Postgres actually parsed is unambiguous proof.

---

## Why Your Date Filter Might NOT Be Pushing (and How to Fix It)

Date and timestamp range predicates push down reliably for PostgreSQL in Trino. If your query is slow despite a date filter, something else is usually the culprit.

### 1. Another predicate in the WHERE clause doesn't push (most common)

Pushdown is **all-or-nothing for the entire scan**. If you have:

```sql
SELECT *
FROM app_pg.public.orders
WHERE created_at >= '2026-01-01'
  AND status = 'pending'           -- string equality, DOES push
  AND customer_email ILIKE '%@acme%'  -- ILIKE, DOES NOT push
```

`ILIKE` does NOT push down to PostgreSQL. Even though the date filter and status filter push, `ILIKE` blocks full predicate pushdown. Postgres returns all matching rows, and Trino filters `ILIKE` in-memory.

**How to fix it:**
- Replace `ILIKE` with `LIKE` (standard case-sensitive, may push on standard collation columns)
- Add a generated lowercase column on Postgres (`lower_email`) and filter on that with `= lower(...)` — explicit equality pushes cleanly
- Accept the slow path if you can't change the query or schema

### 2. Function calls wrapping the column

```sql
-- BAD — function wrapping blocks pushdown:
WHERE date_trunc('day', created_at) = DATE '2026-01-01'

-- GOOD — bare column comparison:
WHERE created_at >= DATE '2026-01-01'
  AND created_at < DATE '2026-01-02'
```

The function call on `created_at` is not translatable to Postgres, so the predicate stays on the Trino side. Rewrite to a bare column comparison with an explicit range.

### 3. Type mismatches on the literal

```sql
-- May have type mismatch (comparing TIMESTAMP column to VARCHAR string):
WHERE created_at >= '2026-01-01'

-- Explicit type — safer:
WHERE created_at >= DATE '2026-01-01'
WHERE created_at >= TIMESTAMP '2026-01-01 00:00:00'
```

Explicit type casts tell Trino the exact type, avoiding coercion-related pushdown failures.

### 4. Large IN-lists exceeding domain_compaction_threshold

If your WHERE clause includes a large IN-list:

```sql
WHERE created_at >= '2026-01-01'
  AND user_id IN ('uuid-1', 'uuid-2', ... 'uuid-500')  -- 500 values
```

By default, Trino caps IN-lists at 256 distinct values. If you exceed that, Trino converts the IN-list to a `BETWEEN min AND max` range before sending to Postgres. If your 500 UUIDs are sparse, the BETWEEN matches far more rows than the original IN-list.

**How to fix it:**
```sql
SET SESSION app_pg.domain_compaction_threshold = 1024;
-- Now run your query
```

---

## The Complete Diagnostic Workflow

1. **`EXPLAIN (TYPE DISTRIBUTED) <query>`** — instant, no execution. Look for `constraint on` under TableScan (success) vs `ScanFilterProject` above TableScan (failure).
2. **If EXPLAIN shows success:** run `EXPLAIN ANALYZE` to check runtime `Input:` row counts. Small `Input` = pushdown worked.
3. **If EXPLAIN shows failure:** look for non-pushable predicates (ILIKE, function calls, type mismatches, large IN-lists). Fix the most selective ones first.
4. **Ground truth:** check `pg_stat_activity` while the query runs — the actual SQL Postgres received is definitive.

**TL;DR:** Date range pushdown works reliably. If your query is still slow despite a date filter, look for other WHERE conditions that don't push (ILIKE, LOWER(), type mismatches, large IN-lists over 256 values). EXPLAIN will show you exactly which predicates failed and where the filtering is happening.
