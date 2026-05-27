# Iter 157 Q1 — Columnar Storage: Why Row Lookups Are Slow but Column Scans Are Fast

## Answer

## Why Single-Row Reads Are Slower in Iceberg/Trino Than Postgres

**The columnar storage design makes single-row lookups slow.** This is not a misconfiguration — it's a fundamental architectural trade-off.

When you sum a single column across hundreds of millions of rows, Trino reads:
- Only the bytes from that one column on disk (in your MinIO Parquet files)
- These bytes are stored contiguously in columnar format, so they decompress very efficiently
- SIMD vectorization and batch processing crunch 8–16 values per CPU instruction

When you fetch one row by ID and need all columns, Trino must:
- Open the Parquet files that might contain that row
- Within each file, read the column data for **every column** you selected, because each column is stored in a separate physical location on disk
- If you do `SELECT *`, that's reading from 20+ different column locations to reconstruct one row

> **The trade-off: columnar is slow for single-row access.** Columnar storage is the wrong choice when you need to read a single row by ID (`SELECT * FROM users WHERE id = 12345`). For those operations, row storage wins. Fetching one row from a row store means reading one contiguous block. **With columnar storage, that same fetch touches a different file region for every column you select — much slower for single-row access.**

### Why This Compares Unfavorably to Postgres

Postgres stores rows as contiguous blocks on disk. Fetching one row by ID:
1. Looks up the row location in an index (microseconds)
2. Reads one disk block containing the entire row (one I/O)
3. Done

Trino on Iceberg must:
1. Read Iceberg manifest metadata to find candidate files
2. Open the Parquet file footer to read schema and row-group statistics
3. Read `N` separate column chunks from the file (one per column), each potentially in a different disk location
4. Decompress each column chunk
5. Reconstruct the row by stitching the columns together

### When Your Query Is Especially Slow

Single-row reads are worst when:

1. **You're not filtering on a partition column.** If you query `WHERE event_id = 'abc123'` but the table is partitioned by `day(occurred_at)` and `tenant_id`, Trino has to open **every partition's files** to find that event. That's a full table scan. Adding `AND occurred_at >= DATE '2026-05-01'` enables partition pruning and cuts files scanned by 90%+.

2. **You're selecting all columns.** Every column you select requires a separate read from Parquet. `SELECT user_id, revenue` is faster than `SELECT *` on a 20-column table.

### What This Means for Your Setup

This is **correct behavior** — not a bug. Your Iceberg + Trino stack excels at bulk analytical queries (scanning one column across billions of rows) **because** it sacrifices single-row lookup performance. That's why you kept Postgres around:

> This is exactly why your SaaS product keeps a transactional database (Postgres/MySQL) for application traffic, and your Iceberg + Trino layer handles analytics. They are good at opposite things, by design.

### If You Need Faster Single-Row Lookups from the Lakehouse

1. **Add a partition filter.** Query `WHERE tenant_id = 'acme' AND event_date >= DATE '2026-05-01'` alongside your ID filter. Partition pruning eliminates 99% of files before opening any Parquet.

2. **Select only the columns you need.** `SELECT user_id, revenue` is faster than `SELECT *`. Columnar storage charges per column read.

3. **Keep single-row queries in Postgres.** If your app needs `SELECT * FROM events WHERE event_id = ?` to be fast, keep that query against your application database. The lakehouse is not designed for this access pattern.
