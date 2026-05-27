# Iter 220 Q1 — MySQL Predicate Pushdown in Trino: What Pushes Down and How to Verify

## Answer

Your suspicion is well-founded — the MySQL connector in Trino has a **much narrower pushdown surface** than the PostgreSQL connector. Here's how to tell what's happening and what to do about it.

### The Critical Difference: MySQL vs PostgreSQL Pushdown

**What DOES push down to MySQL:**
- Numeric predicates (integer, float, decimal)
- Date and timestamp predicates (equality and range: `>=`, `<=`, `=`, `<>`, `BETWEEN`)
- NULL checks: `IS NULL`, `IS NOT NULL`
- IN lists on numeric/date columns

**What does NOT push down to MySQL:**
- VARCHAR equality: `WHERE status = 'paid'` — **does NOT push down**
- VARCHAR LIKE patterns: `WHERE name LIKE 'foo%'` — **does NOT push down**
- String range predicates on VARCHAR/CHAR columns
- IN lists on VARCHAR columns

**There is no flag to enable VARCHAR pushdown for MySQL.** The `experimental.enable-string-pushdown-with-collate` property that exists for the PostgreSQL connector does not exist for the MySQL connector and will either be silently ignored or cause catalog startup to fail if you add it to `billing_mysql.properties`.

### Your Specific Query

```sql
WHERE status = 'paid' AND invoice_date >= DATE '2026-01-01'
```

- `status = 'paid'` — **does NOT push down**. Trino filters this in worker memory after fetching rows from MySQL.
- `invoice_date >= DATE '2026-01-01'` — **does push down** to MySQL. MySQL sends back only rows matching this condition.

So the current situation: MySQL applies the date filter server-side but returns ALL matching-date rows regardless of status. Trino then filters by status in memory. If you have 10 million invoices from 2026 but only 50,000 are 'paid', Trino is shipping 10 million rows over JDBC and discarding 9.95 million.

### How to Verify Using EXPLAIN

Run this first — it's free (no query execution):

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT * FROM billing_mysql.billing.invoices
WHERE status = 'paid' AND invoice_date >= DATE '2026-01-01';
```

Look at the plan tree for the MySQL `TableScan` node:

**Pushdown succeeded** — predicate appears inside the `TableScan` constraint block:
```
TableScan[table=billing_mysql:billing.invoices]
    constraint on [invoice_date]
        invoice_date >= DATE '2026-01-01'
```
The `status` predicate will be in a `ScanFilterProject` or `Filter` node ABOVE the TableScan:
```
Filter[filterPredicate = (status = 'paid')]
    TableScan[table=billing_mysql:billing.invoices]
        constraint on [invoice_date]
            invoice_date >= DATE '2026-01-01'
```

**The key rule**: predicate **under** the TableScan in the `constraint` block = pushed to MySQL. Predicate **above** the TableScan in a Filter/ScanFilterProject node = staying in Trino worker memory.

Run `EXPLAIN ANALYZE` for the runtime confirmation:

```sql
EXPLAIN ANALYZE
SELECT * FROM billing_mysql.billing.invoices
WHERE status = 'paid' AND invoice_date >= DATE '2026-01-01';
```

Look at the `Input:` field and `Filtered:` field on the MySQL TableScan:
- `Filtered: 0%` despite a status filter → the date filter pushed (some filtering happened server-side), but the status filter is running in Trino
- High `Filtered:` % on the TableScan itself → MySQL did the filtering

### The Performance Workaround

Since VARCHAR predicates don't push down on MySQL, the standard pattern is: **pair a non-pushing VARCHAR filter with a pushing numeric or date filter so MySQL only ships a small result set, then let Trino filter the VARCHAR on the smaller result**:

```sql
-- BAD: only the VARCHAR filter — MySQL ships the full table, Trino filters all of it in memory
SELECT * FROM billing_mysql.billing.invoices WHERE status = 'paid';

-- GOOD: add a selective date predicate to push down first
-- MySQL ships only 2026 invoices; Trino's status filter runs on that smaller set
SELECT * FROM billing_mysql.billing.invoices
WHERE invoice_date >= DATE '2026-01-01'   -- pushes to MySQL
  AND status = 'paid';                    -- filtered in Trino on the reduced result
```

If your business queries are mostly for a specific status and don't have a natural date range, consider whether this table should be **ingested into Iceberg** instead. Iceberg supports VARCHAR equality pushdown via Parquet statistics, so `WHERE status = 'paid'` would prune files at scan time rather than pulling all data over JDBC.

### Summary Table for Your Columns

| Your predicate | Pushes to MySQL? | What MySQL sends back |
|---|---|---|
| `status = 'paid'` (VARCHAR) | NO | All rows regardless of status |
| `invoice_date >= DATE '2026-01-01'` (DATE) | YES | Only rows from 2026+ |
| `invoice_date BETWEEN DATE '2026-01-01' AND DATE '2026-05-31'` (DATE) | YES | Only rows in that range |
| `amount > 1000` (numeric) | YES | Only rows where amount > 1000 |
| `customer_name LIKE 'Acme%'` (VARCHAR) | NO | All rows regardless of name |
