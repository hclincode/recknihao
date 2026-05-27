# Iter 172 Q2 — Reading EXPLAIN Output to Verify PostgreSQL Predicate Pushdown

## Answer

Here's exactly how to tell whether Trino is pushing filters down to Postgres or pulling the whole table and filtering locally.

### (1) EXPLAIN vs EXPLAIN ANALYZE

**`EXPLAIN (TYPE DISTRIBUTED)`** (planning-time only, no query execution):
- Shows the query plan WITHOUT executing the query.
- Does NOT run against Postgres — cheap to run repeatedly.
- Tells you what the Trino planner *plans* to do.
- Use this first to check pushdown status.

**`EXPLAIN ANALYZE`** (runs the actual query):
- Executes the entire query and returns the plan PLUS runtime statistics per operator (CPU time, I/O bytes, rows processed).
- The only way to verify what actually happened at runtime.
- Use this after identifying a problem query when you want bulletproof confirmation.

**Start with `EXPLAIN (TYPE DISTRIBUTED)`.** Only run `EXPLAIN ANALYZE` if you need runtime confirmation and are willing to re-run the slow query.

### (2) What the Plan Output Looks Like: Pushdown Succeeded vs Failed

The key is **where the filter sits in the operator tree**.

#### Pushdown SUCCEEDED — predicate inside `TableScan` constraint

When Trino successfully pushes the filter to Postgres, the predicate **disappears from the tree** (Postgres is handling it). The `TableScan` node embeds the predicate in its `constraint` field:

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT * FROM app_pg.public.orders
WHERE status = 'active' AND order_date >= DATE '2026-05-01';
```

**Output (good — pushdown worked):**
```
TableScan[table = app_pg:public.orders, constraint = (status = 'active') AND (order_date >= DATE '2026-05-01')]
    Layout: [id, status, order_date, amount]
```

**What this means:**
- No `ScanFilterProject` node above the `TableScan` — that's the golden signal.
- Trino sent the WHERE clause to Postgres: `SELECT id, status, order_date, amount FROM orders WHERE status = 'active' AND order_date >= DATE '2026-05-01'`
- Postgres used its index and returned only matching rows.
- Network traffic minimized; Trino workers did NOT filter.

#### Pushdown FAILED — `ScanFilterProject` ABOVE the `TableScan`

When pushdown fails, a `ScanFilterProject` or `Filter` node sits **above** the `TableScan` with the predicate in that upper node:

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT * FROM app_pg.public.orders
WHERE email LIKE 'a%' AND order_date >= DATE '2026-05-01';
```

**Output (bad — string LIKE didn't push):**
```
ScanFilterProject[filterPredicate = (email LIKE 'a%')]
    TableScan[table = app_pg:public.orders]
        Layout: [id, email, order_date, amount]
        constraint = (order_date >= DATE '2026-05-01')
```

**What this means:**
- `email LIKE 'a%'` is in the `ScanFilterProject` node above the scan — it was NOT pushed.
- `order_date` constraint is inside `TableScan` (date ranges push by default).
- Trino issued `SELECT id, email, order_date, amount FROM orders WHERE order_date >= '2026-05-01'` to Postgres — ALL rows matching the date, then Trino filtered `LIKE 'a%'` locally.
- This is the slow path — you pulled a huge result set just to apply a filter that should have happened on Postgres.

**Summary table:**

| Plan shape | Pushdown status | Performance |
|---|---|---|
| `TableScan[constraint = (predicate)]`, no filter node above | Succeeded | Fast — only matching rows over network |
| `ScanFilterProject[filterPredicate=(predicate)]` above `TableScan` | Failed | Slow — full result set pulled over JDBC |
| `Filter[predicate]` above any scan | Failed | Slow — same reason |

**The key visual signal:** If you see a filter/scan node sitting ABOVE the `TableScan`, pushdown failed for that predicate. If the predicate is **inside** the `TableScan`'s `constraint=()`, pushdown succeeded.

### (3) Verify with pg_stat_activity (the definitive Postgres-side proof)

EXPLAIN shows what Trino *planned* to do. The only bulletproof way to see what SQL Postgres actually received is to watch the replica's query log while the Trino query runs:

```sql
-- On the Postgres replica, watch what Trino sends:
SELECT 
  usename,
  application_name,
  query,
  state
FROM pg_stat_activity
WHERE usename = 'trino_reader';
```

**Look at the `query` column:**
- **Pushdown succeeded:** `SELECT id, status, order_date, amount FROM orders WHERE status = 'active' AND order_date >= '2026-05-01'`
- **Pushdown failed:** `SELECT id, email, order_date, amount FROM orders WHERE order_date >= '2026-05-01'` — the LIKE filter is absent, meaning Trino filtered it locally after fetching everything

This is the **definitive proof** — what Postgres actually received is ground truth.

### (4) What Trino Pushes Down vs Cannot Push Down

**Pushes down by default:**
- Equality on any type: `WHERE id = 12345`, `WHERE status = 'active'`, `WHERE tenant_id = uuid`
- Numeric/date ranges: `WHERE amount BETWEEN 100 AND 500`, `WHERE created_at > TIMESTAMP '2026-05-01 00:00:00'`
- `IN` lists: `WHERE id IN (1, 2, 3)`
- `IS NULL` / `IS NOT NULL`: `WHERE deleted_at IS NULL`

**Does NOT push down:**
- **String range predicates** (the main gotcha): `WHERE email LIKE 'a%'`, `WHERE name > 'm'`
  - Why: character collation differs between Postgres and Trino; pushing the range could return wrong rows.
- **Function calls**: `WHERE LOWER(email) = 'foo@bar'`, `WHERE SUBSTRING(name, 1, 3) = 'abc'`
  - Trino can't peer through functions to push them, so the full column is returned.

**Practical example:**
```sql
-- WILL push (equality on string):
SELECT * FROM app_pg.public.users WHERE plan = 'enterprise';

-- WON'T push (range on string — Trino filters locally):
SELECT * FROM app_pg.public.users WHERE plan > 'a';  -- slow!

-- WON'T push (function call):
SELECT * FROM app_pg.public.users WHERE LOWER(email) = 'user@example.com';  -- slow!
```

### (5) What to Do If Pushdown Isn't Working

**Fix 1 — Enable string pushdown (experimental) for string-range predicates:**
```properties
# /etc/trino/catalog/app_pg.properties
postgresql.experimental.enable-string-pushdown-with-collate=true
```
Adds a COLLATE clause for safety. Test on non-prod replica first — can disable index usage in some cases.

**Fix 2 — Rewrite to avoid function calls:**
```sql
-- Bad (won't push LOWER):
SELECT * FROM app_pg.public.users WHERE LOWER(email) = 'user@example.com';

-- Better (ILIKE pushes as case-insensitive equality):
SELECT * FROM app_pg.public.users WHERE email ILIKE 'user@example.com';
```

**Two-step verification workflow:**
1. `EXPLAIN (TYPE DISTRIBUTED)` — look for `ScanFilterProject` vs predicate inside `TableScan` constraint.
2. Check Postgres replica's `pg_stat_activity` — look at the actual SQL received to confirm.

If the replica shows a bare `SELECT` without your filter, you've confirmed the problem. The filter didn't push; Trino is pulling everything and filtering locally.
