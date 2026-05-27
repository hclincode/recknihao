# Iter245 Q2 — MySQL vs PostgreSQL Federation: What's Actually Different

## Your coworker is right — MySQL federation in Trino is significantly more limited than PostgreSQL.

The difference comes down to **predicate pushdown** — the mechanism that decides whether Trino can push a WHERE clause down to the database itself (fast), or whether the database has to ship all unfiltered rows back to Trino workers for in-memory filtering (slow). The two connectors have fundamentally different rules about what filters push down.

### The critical difference: VARCHAR and text filters

**PostgreSQL connector**: VARCHAR columns support pushdown for equality (`WHERE status = 'active'`), IN-lists (`WHERE status IN ('paid', 'pending')`), and NULL checks by default.

**MySQL connector**: **ZERO VARCHAR predicates push down** — not equality, not IN-lists, not LIKE patterns, not NULL checks on text columns. Any WHERE clause that filters on a text column stays on Trino workers. The database ships the entire unfiltered table back over JDBC.

This means a query like:
```sql
SELECT * FROM billing_mysql.billing.invoices
WHERE status = 'paid'
```

Will pull **every row from the MySQL table over the network** (potentially millions), then Trino filters in memory. The same query on PostgreSQL pushes `status = 'paid'` down to the database.

### What DOES push down to MySQL

Only:
- Numeric comparisons (`WHERE id = 42`, `WHERE amount > 100`)
- Date/timestamp comparisons (`WHERE created_at >= '2026-01-01'`)
- IN-lists on numeric or date columns
- NULL checks on numeric or date columns

Text column filters of any kind fail silently at pushdown — they don't error, they just run inefficiently.

### The dynamic filtering problem (the sneaky one)

If you join a small Iceberg table to a large MySQL table on a text/VARCHAR column (like a string user ID), Trino's dynamic filtering — which pushes a derived IN-list to prune the large side — **will not work**. Trino still pulls all rows from MySQL.

```sql
-- If user_id is VARCHAR(36), this scans ALL invoices in MySQL
-- then applies the IN-list in Trino memory (defeats the optimization)
SELECT *
FROM iceberg.sales.users          -- smaller side, becomes build side
JOIN billing_mysql.billing.invoices
  ON iceberg.sales.users.user_id = billing_mysql.billing.invoices.user_id
```

The fix: join on a numeric or date column if you have one. If you don't, keep the dimension data in PostgreSQL instead (the Postgres connector pushes VARCHAR equality), or accept full-table scans and constrain with a co-predicate that DOES push (a date range + the VARCHAR filter).

### Concrete example of silent degradation

A dashboard query that filters on `WHERE subscription_status = 'active'` runs fast on Postgres (that pushes down, database does the filtering). The same query on MySQL will suddenly become slow — MySQL ships millions of rows, Trino filters in memory — but it will **still return correct results without any error**. You'll notice it at 2 AM when CPU spikes on the Trino cluster.

### The workaround

Always pair a VARCHAR filter with a pushdown-able numeric or date predicate:

```sql
-- Good for MySQL: the date range pushes, MySQL ships fewer rows,
-- then Trino applies the status filter in memory on a smaller set
SELECT *
FROM billing_mysql.billing.invoices
WHERE created_at >= DATE '2026-01-01'   -- pushes to MySQL
  AND status = 'paid';                  -- filtered in Trino memory
```

### Other MySQL-specific gotchas

1. **JDBC timeout units differ**: PostgreSQL JDBC uses seconds; MySQL Connector/J uses milliseconds. If you copy `socketTimeout=60` from your Postgres config to MySQL, it becomes 60 milliseconds and kills every query instantly.

2. **SSL/TLS property names differ**: Postgres uses `ssl=true&sslmode=verify-full&sslrootcert=/path.pem`; MySQL uses `sslMode=VERIFY_IDENTITY&trustCertificateKeyStoreUrl=/path.jks` (and the cert must be JKS format, not PEM).

3. **DELETE with VARCHAR predicates fails entirely**: `DELETE FROM t WHERE status = 'paid'` will fail at planning time on MySQL (you can't push a non-pushdown predicate to a DELETE). You must pair it with a pushing predicate.

4. **VARCHAR IS NULL is not pushed**: While `IS NULL` on a date or numeric column pushes down fine, on text columns it stays in Trino.

### How to verify before deploying to production

Use `EXPLAIN` to verify — if you see a `ScanFilterProject` node above a `TableScan` for MySQL, that filter is not pushing. Test your dashboard queries on a subset of MySQL data first; production will feel very different if you have any significant text-column filtering.

### Bottom line

| | PostgreSQL | MySQL |
|---|---|---|
| VARCHAR equality (`= 'active'`) | Pushes down ✓ | Does NOT push ✗ |
| VARCHAR IN-list | Pushes down ✓ | Does NOT push ✗ |
| VARCHAR range (`BETWEEN`) | Does NOT push ✗ | Does NOT push ✗ |
| Numeric equality/range | Pushes down ✓ | Pushes down ✓ |
| Date/timestamp range | Pushes down ✓ | Pushes down ✓ |
| Dynamic filter IN-list on text join key | Pushes into PostgreSQL ✓ | Does NOT push ✗ |

You cannot use MySQL the way you use PostgreSQL in Trino federation. Plan every WHERE clause around the fact that only numeric and date filters push down.
