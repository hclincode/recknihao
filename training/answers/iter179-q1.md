# Iter 179 Q1 — Diagnosing Predicate Pushdown Failure to Postgres

## Answer

### How to Confirm Pushdown Is Failing

**Step 1: EXPLAIN (TYPE DISTRIBUTED) — doesn't run the query**

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT * FROM billing_pg.public.invoices
WHERE billing_date >= DATE '2026-05-01';
```

**Pushdown SUCCEEDED** — filter embedded inside the TableScan:
```
TableScan[table = billing_pg:public.invoices, ...]
    constraint on [billing_date]
        billing_date >= DATE '2026-05-01'
```

**Pushdown FAILED** — `ScanFilterProject` or `Filter` node sits ABOVE the TableScan:
```
ScanFilterProject[filterPredicate = (billing_date >= DATE '2026-05-01')]
    TableScan[table = billing_pg:public.invoices]
```

When pushdown fails, Postgres returns all rows unfiltered and Trino workers apply the filter in-memory after the JDBC fetch.

**Step 2: EXPLAIN ANALYZE — runs the query, definitive runtime proof**

```sql
EXPLAIN ANALYZE
SELECT * FROM billing_pg.public.invoices
WHERE billing_date >= DATE '2026-05-01';
```

Key fields on the Postgres TableScan node:
- **`Filtered: X%`** — Non-zero means Postgres filtered rows server-side. `Filtered: 0%` or absent with a large `Input:` count = pushdown failed.
- **`Input: N rows (size)`** — Compare to your table's total row count. If `Input:` matches the full table size with `Filtered: 0%`, pushdown failed completely.

Example of successful pushdown:
```
TableScan[table = billing_pg:public.invoices, ...]
    Input: 520000 rows (45MB)
    Filtered: 97.3%
    constraint on [billing_date]
        billing_date >= DATE '2026-05-01'
```

**Step 3: Enable Postgres slow-query logging (ground truth)**

Enable temporarily on your read replica:
```sql
ALTER SYSTEM SET log_min_duration_statement = 0;
SELECT pg_reload_conf();
```

Then run your Trino query. Check Postgres logs for the actual SQL it received:
- Pushdown succeeded: `SELECT ... FROM invoices WHERE billing_date >= '2026-05-01'`
- Pushdown failed: `SELECT col1, col2, ... FROM invoices` — no WHERE clause

This is the definitive proof — the SQL Postgres actually receives never lies.

---

### Most Common Reasons Pushdown Fails

**1. Data type mismatch (most common)**

Trino can't guarantee comparisons work identically in Postgres when types don't match:

```sql
-- FAILS: string literal vs numeric column
WHERE id = '12345'          -- '12345' is a string, id is BIGINT

-- FAILS: implicit cast
WHERE created_at = '2026-05-01'    -- string vs TIMESTAMP

-- SUCCEEDS: explicit type literals
WHERE id = BIGINT '12345'
WHERE created_at = TIMESTAMP '2026-05-01 00:00:00'
WHERE created_at >= DATE '2026-05-01'
```

**Fix:** Use explicit type literals. Check column types with `DESCRIBE billing_pg.public.invoices` from Trino, then match them in your WHERE clause.

**2. String range predicates (LIKE, >, <, BETWEEN)**

String comparisons depend on collation — Postgres uses locale-aware collation, Trino uses byte-wise. Pushing a range predicate silently could return wrong rows, so Trino conservatively doesn't push.

```sql
-- FAILS by default: range on VARCHAR
WHERE email LIKE 'a%'
WHERE name > 'M'
WHERE status BETWEEN 'a' AND 'z'

-- SUCCEEDS: equality on strings always pushes
WHERE status = 'active'
WHERE email = 'user@example.com'
```

**Fix — Option A (recommended):** Denormalize on the Postgres side:
```sql
-- One-time setup on Postgres:
ALTER TABLE invoices ADD COLUMN billing_month TEXT
    GENERATED ALWAYS AS (TO_CHAR(billing_date, 'YYYY-MM')) STORED;
CREATE INDEX idx_billing_month ON invoices (billing_month);

-- From Trino — equality pushes cleanly:
SELECT * FROM billing_pg.public.invoices WHERE billing_month = '2026-05';
```

**Fix — Option B (experimental):** Enable the experimental flag (test on non-prod first):
```properties
# In etc/catalog/billing_pg.properties
postgresql.experimental.enable-string-pushdown-with-collate=true
```

Re-test with `EXPLAIN ANALYZE`. Can disable Postgres index usage in some cases.

**3. Function calls on the column**

Trino cannot rewrite arbitrary function expressions into Postgres SQL:

```sql
-- FAILS: function on the column
WHERE LOWER(email) = 'user@example.com'
WHERE SUBSTRING(order_id, 1, 3) = 'ORD'
WHERE DATE(created_at) = CURRENT_DATE

-- SUCCEEDS: column alone, no function
WHERE email = 'user@example.com'
WHERE created_at >= TIMESTAMP '2026-05-26 00:00:00'
  AND created_at < TIMESTAMP '2026-05-27 00:00:00'
```

**Fix:** Add a generated column on Postgres and index it:
```sql
ALTER TABLE users ADD COLUMN lower_email TEXT
    GENERATED ALWAYS AS (LOWER(email)) STORED;
CREATE INDEX idx_lower_email ON users (lower_email);

-- From Trino — now pushes down and uses the index:
SELECT * FROM billing_pg.public.users WHERE lower_email = 'user@example.com';
```

**4. Missing index on Postgres (pushdown works, but still slow)**

The filter pushes down, but Postgres performs a sequential scan because there's no index. You'll see a high `Filtered:` % in EXPLAIN ANALYZE (proof Postgres filtered) but slow wall time.

```sql
-- On Postgres read replica:
CREATE INDEX idx_invoices_billing_date ON invoices (billing_date);
```

---

### Verification Checklist

1. **Run `EXPLAIN (TYPE DISTRIBUTED)`** — look for `constraint on [column]` inside the TableScan node.
2. **If constraint is missing, run `EXPLAIN ANALYZE`** — check `Filtered:` % and compare `Input:` rows to the table's actual size.
3. **Check the Postgres column type** — `DESCRIBE billing_pg.public.invoices`.
4. **Fix data types in your WHERE clause** — use explicit literals: `DATE '...'`, `TIMESTAMP '...'`, `BIGINT '...'`.
5. **If it's a string range (LIKE, >, <, BETWEEN)** — denormalize or enable the experimental flag; test the latter on non-prod first.
6. **If it's a function (LOWER, SUBSTRING, DATE)** — add a generated column and index it.
7. **Enable Postgres logs temporarily** to see the actual SQL Postgres receives.
