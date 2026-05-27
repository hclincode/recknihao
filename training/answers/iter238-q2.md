# Iter 238 Q2 — PostgreSQL WHERE Clause Pushdown: Which Filters Run at the Database?

## Answer

### Your Three WHERE Conditions and PostgreSQL Predicate Pushdown

**1. `status = 'active'` (VARCHAR equality) — YES, PUSHES DOWN**

Equality on VARCHAR columns is one of the predicates PostgreSQL connector **does push down by default**. Trino sends this down to PostgreSQL as part of the WHERE clause. PostgreSQL receives: `SELECT ... FROM subscriptions WHERE status = 'active'` and applies the filter server-side before returning rows over JDBC.

**2. `created_at BETWEEN '2025-01-01' AND '2025-06-01'` (date range) — YES, PUSHES DOWN**

Date/timestamp range predicates push down to PostgreSQL. The BETWEEN form is a range filter on a date column, and numeric/date ranges are unconditionally pushed. PostgreSQL applies this filter server-side and only streams back matching rows.

**3. `company_name LIKE '%acme%'` (LIKE with leading wildcard) — NO, DOES NOT PUSH DOWN**

This is the critical one. LIKE predicates with leading wildcards (unanchored patterns like `'%acme%'`) do **not** push down to PostgreSQL. Anchored patterns like `'foo%'` may push down (behavior is collation-dependent), but leading-wildcard patterns are not pushed.

So Trino will **pull all rows matching the first two conditions** (status + date) from PostgreSQL, then apply the `LIKE '%acme%'` filter on the Trino worker in memory.

### The Net Result

- **PostgreSQL sees**: `SELECT ... FROM subscriptions WHERE status = 'active' AND created_at BETWEEN '2025-01-01' AND '2025-06-01'`
- **PostgreSQL applies those two filters** and returns only matching rows over JDBC
- **Trino receives those rows** and applies `LIKE '%acme%'` in-memory on the workers

Only the first two conditions actually reduce the data pulled across the wire. If your subscriptions table has 10 million rows but only 200,000 are `status = 'active'` in that date range, you pull 200,000 rows across JDBC and filter those in Trino. The `LIKE '%acme%'` filter runs in Trino memory on those 200,000 rows — not a problem if they're already selective, but a problem if status+date filtering is not selective.

### How to Verify with EXPLAIN

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT * FROM app_pg.public.subscriptions
WHERE status = 'active'
  AND created_at BETWEEN '2025-01-01' AND '2025-06-01'
  AND company_name LIKE '%acme%';
```

Read the output:
- **Predicate inside the `TableScan` node** (as `constraint on [status, created_at]`) = pushed to PostgreSQL ✓
- **A separate `Filter` or `ScanFilterProject` node ABOVE the `TableScan`** containing `company_name LIKE '%acme%'` = filtered by Trino workers in memory

The key rule: **inside TableScan = pushed to database; above TableScan in a Filter node = applied in Trino memory**.

### MySQL vs PostgreSQL Note

This answer is specific to PostgreSQL. If you were using MySQL instead, **all three conditions would NOT push down** — the MySQL connector excludes ALL VARCHAR predicates (equality, IN-lists, LIKE, and IS NULL on text columns). PostgreSQL is more permissive: equality and IN-lists on VARCHAR push down by default; only range predicates and LIKE with leading wildcards are restricted.

This is one of the key reasons to prefer PostgreSQL over MySQL for federated queries involving string filter conditions.
