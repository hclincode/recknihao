# Iter 184 Q2 — CTE Predicate Pushdown to Postgres Federation Catalogs

## Answer

Your `created_at` predicate inside the CTE will push down to Postgres. Here's why, and how to verify it.

---

### How Trino handles CTEs: inlined, not materialized

CTEs (`WITH recent_billing AS (...)`) are **inlined** by Trino's planner by default — not materialized as temporary tables. The planner expands the CTE body directly into the main query at planning time, then applies the same pushdown rules as it would for an inline subquery or direct `WHERE` clause. **Wrapping a predicate in a CTE does not change whether pushdown happens.**

---

### Timestamp range predicates DO push down to Postgres

Your predicate — `created_at > now() - interval '30' day` — is a **range predicate on a TIMESTAMP column**. Trino's PostgreSQL connector pushes these down by default:

| Predicate type | Pushes down by default? |
|---|---|
| Range on TIMESTAMP/DATE columns | **Yes** |
| Equality on TIMESTAMP/DATE columns | Yes |
| Ranges on numeric columns | Yes |
| `IS NULL` / `IS NOT NULL` | Yes |
| Range on VARCHAR/CHAR columns | No (collation risk) — needs `enable_string_pushdown_with_collate` |

The VARCHAR/range caveat does NOT apply to your case — `created_at` is a TIMESTAMP column. Trino sends the predicate to Postgres as part of the scan, and Postgres filters rows at the server before streaming them over JDBC.

---

### How to verify with EXPLAIN

```sql
EXPLAIN (TYPE DISTRIBUTED)
WITH recent_billing AS (
  SELECT invoice_id, customer_id, amount, created_at
  FROM billing_pg.public.invoices
  WHERE created_at > now() - interval '30' day
)
SELECT rb.customer_id, rb.amount, e.event_type
FROM recent_billing rb
JOIN iceberg.analytics.events e ON rb.customer_id = e.customer_id;
```

**Pushdown succeeded** — look for this in the `billing_pg` TableScan node:
```
TableScan[table = billing_pg:public.invoices, ...]
    constraint on [created_at]
        created_at > now() - interval '30' day
```

The predicate appears **inside** the TableScan constraint — Postgres applies it server-side.

**Pushdown failed** — if you see this instead:
```
Filter[created_at > now() - interval '30' day]
  TableScan[table = billing_pg:public.invoices, ...]
```

A `Filter` (or `ScanFilterProject`) node **above** the TableScan means Trino pulled all rows from Postgres and filtered locally. For millions of rows this is a disaster.

For runtime confirmation, use `EXPLAIN ANALYZE` — it actually runs the query and reports `Filtered: X%` on the TableScan node. `Filtered: 99%` means Postgres filtered 99% of rows server-side (good). `Filtered: 0%` with a multi-million row `Input:` count means all rows came over the wire and Trino filtered (bad).

---

### Cases where pushdown can fail inside a CTE

1. **Predicate references an outer-query column** — if the CTE's `WHERE` clause references a value computed in the main query body (a correlated CTE), Trino cannot push the predicate to Postgres. Your case doesn't do this.

2. **Column is wrapped in a function** — `WHERE LOWER(category) = 'active'` or `WHERE EXTRACT(YEAR FROM created_at) = 2026` wraps the column in a function call, breaking pushdown. Use the raw column on the left side: `WHERE created_at >= TIMESTAMP '2026-01-01'`.

3. **`SELECT *` in the CTE pulls all columns** — not a pushdown failure, but `SELECT *` pulls every column over JDBC regardless of what the main query actually uses. Write explicit column lists (`SELECT invoice_id, customer_id, amount, created_at`) to reduce bytes on the wire.

4. **Very complex CTE structures** — deeply nested CTEs or CTEs referenced multiple times can sometimes prevent inlining. This is uncommon. Verify with EXPLAIN if your query is unusually complex.

---

### The function-call trap with `now()`

Your predicate `created_at > now() - interval '30' day` uses the `now()` function. This still pushes down fine — Trino evaluates `now()` to a timestamp literal at planning time and sends the bound to Postgres. What does NOT push down is a function applied to the **column** itself:

```sql
-- GOOD: pushes down (function on the right side)
WHERE created_at > now() - interval '30' day

-- BAD: does NOT push down (function wraps the column)
WHERE CAST(created_at AS DATE) > CURRENT_DATE - interval '30' day
WHERE DATE_TRUNC('day', created_at) > CURRENT_DATE - 30
```

If you need date-only comparison, use a range on the TIMESTAMP column: `WHERE created_at >= TIMESTAMP '2026-04-26 00:00:00'`.

---

### Practical advice

1. **Your CTE structure is fine** — predicate on the remote table inside the CTE body, joined to Iceberg. Trino inlines it and pushes the predicate down as normal.
2. **Use explicit column lists** in the CTE, not `SELECT *` — reduces JDBC data volume.
3. **Verify with EXPLAIN before assuming pushdown** — run once, look for `constraint on [created_at]` inside the TableScan.
4. **Index on `created_at`** on the Postgres replica — predicate pushdown only helps if Postgres can use an index for the range scan. Check with `SELECT indexname FROM pg_indexes WHERE tablename = 'invoices' AND indexdef LIKE '%created_at%'`.

Your query will pull only the last 30 days of invoices from Postgres — not the full table. The CTE wrapper changes nothing about this behavior.
