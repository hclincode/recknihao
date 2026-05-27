# Iter 226 Q2 — Federation Write Operations: INSERT/UPDATE/DELETE into MySQL via Trino

## Answer

Yes, Trino supports write operations into MySQL via federation — with important caveats.

You can write from Trino into your `billing_mysql` catalog using `INSERT`, `UPDATE`, `DELETE`, `CREATE TABLE`, and `DROP TABLE`. The MySQL connector supports the same DML operations as the PostgreSQL connector. This means your `INSERT INTO billing_mysql.invoices SELECT ... FROM iceberg...` query is syntactically valid and will execute.

### What Write Operations Are Supported

The MySQL connector (a JDBC connector like PostgreSQL and SQL Server) supports:
- `SELECT` — fully supported with predicate pushdown for numeric/date filters
- `INSERT` — supported (see transactional caveats below)
- `UPDATE` — supported with restrictions (constant assignments only)
- `DELETE` — supported with pushdown restrictions
- `CREATE TABLE` / `DROP TABLE` — supported

Your cross-catalog `INSERT INTO billing_mysql.invoices SELECT ... FROM iceberg.analytics.computed_data` is valid syntax and will execute.

### Gotchas You Must Know Before Writing

**For INSERT:**
By default, Trino uses a temporary-table-then-rename pattern to protect against partial failures. You can bypass this with `insert.non-transactional-insert.enabled=true` in your catalog properties, but this risks leaving orphaned rows if the insert fails mid-way. For batch inserts of analytical results, the default behavior is safer.

**For UPDATE — constant assignments only:**
Only constant value assignments are supported. You **cannot** do:
```sql
-- This will FAIL:
UPDATE billing_mysql.invoices SET balance = balance + 100 WHERE id = 42
```
You can only do:
```sql
-- This is fine:
UPDATE billing_mysql.invoices SET status = 'paid' WHERE id = 42
```
Expression-based updates (arithmetic, function calls, references to other columns) must run directly in MySQL, not through Trino.

**For DELETE — predicate pushdown limitation:**
DELETE only works efficiently when Trino can push the predicate down to MySQL. Numeric and date column filters push down. VARCHAR column filters do NOT push down for MySQL JDBC. If your DELETE uses a VARCHAR filter like:
```sql
DELETE FROM billing_mysql.invoices WHERE status = 'pending'
```
Trino will fetch all rows, filter locally, then delete — which is extremely slow and dangerous for large tables. For VARCHAR-filtered deletes, run them directly in MySQL.

**No transactional atomicity — this is critical:**
UPDATE and DELETE through Trino are **NOT wrapped in a single MySQL transaction**. If a multi-row DELETE fails partway through, the first batch of rows stays deleted even if subsequent batches fail. For operations where atomicity matters, run the mutation directly through your application's MySQL connection, not through Trino. The federation connector is designed for analytical reads, not reliable transactional writes.

### OPA Authorization Will Likely Block Writes

If your cluster uses OPA for authorization, note that OPA can (and typically should) deny all DML operations against the `billing_mysql` catalog at the policy layer, regardless of what the connector technically supports. Before you attempt a write, check your cluster's OPA policy — you may get an authorization error before the query even reaches MySQL. This is intentional design: federation is primarily meant for analytical reads.

### Practical Recommendation

Writes to MySQL via Trino are possible but should be used carefully on a live OLTP database:
- Restrict yourself to **idempotent operations** (safe to re-run if they fail partway)
- Use constant-only UPDATE assignments
- Add a numeric or date filter to every DELETE (avoid VARCHAR-filtered deletes through Trino)
- Test on a non-production replica first

For bulk writes that require atomicity or expression-based mutations, use your application's own MySQL connection pool inside a proper transaction instead of routing through Trino.

### Summary

| Operation | Supported via Trino→MySQL? | Caveats |
|---|---|---|
| INSERT | Yes | Non-transactional by default; orphan risk on failure |
| UPDATE | Yes | Constant assignments only; no expression-based updates |
| DELETE | Yes | VARCHAR filters don't push down — fetch-all risk on large tables |
| CREATE TABLE | Yes | — |
| DROP TABLE | Yes | — |
| MERGE | No | Not supported on MySQL JDBC connector |
