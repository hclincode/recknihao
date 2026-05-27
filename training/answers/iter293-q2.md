# Iter293 Q2 — What SELECT * Actually Costs in Trino vs Postgres

## Short answer

In Postgres, `SELECT *` vs naming columns barely matters — the page is fetched either way. In Trino on Iceberg, `SELECT *` forces Trino to read every column's data from MinIO. On a 50-column table, `SELECT *` can be 25x more I/O than `SELECT col1, col2`. The difference is real and measurable.

## Why Postgres and Trino behave differently

**Postgres (row-oriented)**: All 80 columns of a row sit together on disk in a page. Fetching that page gives you every column. Whether your SELECT asks for 2 columns or 80, the same page was read. The database can drop unused columns before sending them to your app, but the disk I/O is the same.

**Trino + Parquet (column-oriented)**: Each column is stored as its own contiguous byte range in the file. Trino's Parquet reader has a choice: open the `revenue` column chunk and the `user_id` column chunk, or open all 80 chunks. It opens only what you listed in SELECT. If you write `SELECT *`, it opens all 80.

## Where Trino stops reading — the three layers

**Layer 1 — Iceberg manifest (whole files)**
Before any data is read, Iceberg's manifest tells Trino which Parquet files match your WHERE clause. Partition-filtered files are skipped entirely. Same for `SELECT *` or `SELECT col1` — this layer is about file selection, not column selection.

**Layer 2 — Parquet row-group (chunks inside files)**
Each Parquet file contains multiple row groups (~128 MB each), each with per-column min/max statistics. Trino skips entire row groups that can't match your WHERE predicate. Still column-independent.

**Layer 3 — Column chunks (where SELECT * actually hits)**
Once Trino decides which row groups to read, it asks: which columns? For `SELECT event_id, user_id`, it opens exactly 2 column chunks per row group. For `SELECT *`, it opens all of them. Each column chunk must be:
- Read from MinIO over the network
- Decompressed in memory on the Trino worker
- Decoded (dictionary decoded, delta decoded, etc.)

Every column you don't need but force Trino to read burns real I/O and CPU.

## Concrete example

50-column `events` table, one day's partition = 50 MB compressed in MinIO:

```sql
-- Reads ~3 column chunks (~3 MB) — fast
SELECT event_id, user_id, amount
FROM events
WHERE event_date = DATE '2026-05-26';

-- Reads all 50 column chunks (~50 MB) — 16x more I/O
SELECT *
FROM events
WHERE event_date = DATE '2026-05-26';
```

Same WHERE clause, same partition files selected, same row groups. The only difference is how many column chunks Trino decompresses. On a 50-column table reading 3 columns, you're using 6% of the I/O that `SELECT *` would cost.

## Practical rules

- **Named columns in production**: always name what you need. Use `DESCRIBE events` to see the schema first.
- **SELECT * in exploration**: acceptable for ad-hoc `LIMIT 10` queries where you're exploring the schema, but add a partition filter first to keep the scan small.
- **For wide dashboards**: if your dashboard genuinely needs 20+ columns, consider a pre-aggregated rollup table (a nightly dbt model) that pre-selects those columns so dashboards query a narrower, cheaper table.
- **Verify with EXPLAIN ANALYZE**: `Physical Input: X GB` in the output shows you exactly how many bytes Trino read. Try your query with named columns vs `SELECT *` — the difference in Physical Input is the SELECT * tax.
