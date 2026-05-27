# Iter 221 Q2 — COUNT Pushdown with Mixed WHERE Clause on MySQL: What Actually Happens

## Answer

Your query has a **mixed pushdown situation** — some parts push down to MySQL, others do not, and the COUNT aggregate is affected by both. Let me break down exactly what happens.

### What Pushes Down in Your Query

In `SELECT COUNT(*) FROM billing_mysql.billing.invoices WHERE status = 'paid' AND invoice_date >= DATE '2026-01-01'`:

- **`invoice_date >= DATE '2026-01-01'`**: This DATE range predicate **DOES push down to MySQL**. MySQL filters the invoices table and returns only rows matching this date range.

- **`status = 'paid'`**: This VARCHAR equality predicate **does NOT push down to MySQL**. The MySQL connector cannot push any textual predicates — not VARCHAR equality, not LIKE patterns, not IN-lists on text columns, nothing. All predicates on textual (CHAR/VARCHAR) columns stay in Trino worker memory.

### What Happens to the COUNT

Aggregate pushdown (COUNT, SUM, AVG, MIN, MAX) is a **separate mechanism from predicate pushdown — they can succeed or fail independently**. But in your query, the COUNT cannot push down because of the VARCHAR filter.

Here's the actual execution flow:

1. MySQL receives: "Give me all rows where `invoice_date >= DATE '2026-01-01'`" — the date predicate pushes to MySQL.
2. MySQL returns all matching rows for that date range to Trino over JDBC (potentially millions of rows).
3. **Trino filters those rows in worker memory** for `status = 'paid'`.
4. **Trino counts the remaining rows** — MySQL never computed the count.

MySQL is NOT returning one number. **Trino is pulling rows over JDBC and counting them itself.** The COUNT only pushes down when MySQL can compute the complete answer — which requires all WHERE predicates to also push down. Since `status = 'paid'` doesn't push, MySQL can't compute the final count, so Trino does it.

### Why This Matters for Performance

If your invoices table has millions of rows per month, and only a small fraction have `status = 'paid'`, this query is wasteful:
- MySQL ships **all rows from the date range** over JDBC (the expensive part — potentially gigabytes).
- Trino filters in worker memory and counts.

If your date range spans multiple months and your table has millions of rows, this is why the query is slow.

### How to Verify with EXPLAIN

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT COUNT(*)
FROM billing_mysql.billing.invoices
WHERE status = 'paid'
  AND invoice_date >= DATE '2026-01-01';
```

Look at the plan tree:

- **Slow path (what you have)**: A `ScanFilterProject` or `Filter` node sits **ABOVE** the `TableScan`. The `status = 'paid'` predicate is in that Filter node, not in the TableScan's constraint. This means Trino fetches rows from MySQL and filters locally.

- **Fast path (what you want but can't achieve with VARCHAR filter)**: If all predicates pushed down, you'd see a `TableScan` with both predicates in its `constraint` block, and the COUNT aggregation might also appear embedded inside the scan. You won't see this with your current query.

Also run `EXPLAIN ANALYZE` on a small date range to see actual row counts:
```
TableScan[table=billing_mysql:billing.invoices]
    Input: 2500000 rows (245MB)   ← MySQL shipped 2.5M rows
    Filtered: 97.2%               ← Trino filtered in memory
```
If `Input:` is large and `Filtered:` is high, the VARCHAR filter is responsible for most of the work happening in Trino memory.

### How to Fix It

**Approach 1: Narrow the date range to reduce what MySQL ships**

```sql
SELECT COUNT(*)
FROM billing_mysql.billing.invoices
WHERE invoice_date >= DATE '2026-01-01'   -- pushes to MySQL
  AND invoice_date < DATE '2026-02-01'    -- pushes to MySQL (tighter window)
  AND status = 'paid';                    -- filtered in Trino on smaller set
```

With a tighter date range, MySQL ships far fewer rows and Trino's in-memory filter runs on a manageable dataset.

**Approach 2: Add a numeric column that correlates with status**

If your schema has a `status_code` (integer) column alongside `status` (VARCHAR), use the integer version — it DOES push down to MySQL:

```sql
SELECT COUNT(*)
FROM billing_mysql.billing.invoices
WHERE invoice_date >= DATE '2026-01-01'  -- pushes to MySQL
  AND status_code = 1                    -- pushes to MySQL (numeric!)
  AND status = 'paid';                   -- safety check in Trino
```

**Approach 3: Ingest the table into Iceberg (long-term)**

For a table queried frequently with VARCHAR filters, ingest it into Iceberg. Iceberg uses Parquet column statistics to prune files at scan time — `WHERE status = 'paid'` would skip Parquet row groups where no 'paid' values exist, without pulling data over JDBC at all.

### The Key Takeaway

**MySQL connector does not push down VARCHAR predicates — ever.** This is the single most important behavioral difference from the PostgreSQL connector (which supports VARCHAR equality and simple LIKE pushdown since Trino 365). Always pair a MySQL VARCHAR filter with a selective numeric or date filter to control how many rows MySQL ships to Trino. Without that anchor, you're pulling the full matching-date dataset over JDBC no matter how specific your VARCHAR filter is.
