# Iter51 Q1 Answer — Storage sizing for Iceberg on MinIO

**Question**: 500M-row Postgres events table, ~250 GB on disk, growing 50M rows/month. Migrating to Iceberg on MinIO. How much storage to budget?

---

## Your 250 GB Postgres database will become approximately 15–25 GB in Iceberg

Parquet compression saves you dramatically. The key insight: the 250 GB in Postgres includes overhead that doesn't transfer to Iceberg.

### What's in those 250 GB

Your Postgres on-disk size includes:
- **Indexes** — typically 30–50% of table size. Parquet uses partition pruning and columnar min/max statistics instead, so indexes don't exist in Iceberg
- **MVCC dead tuples and page bloat** — Postgres's versioning system leaves ghost rows on disk until `VACUUM` runs; 20–40% overhead is common on high-write tables
- **Row header overhead** — ~23 bytes per row in Postgres, regardless of actual data size
- **Actual row data** — what you're actually migrating

So you likely have only 100–150 GB of true row data in that 250 GB. Run this to verify:

```sql
SELECT
  relname AS table_name,
  pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
  pg_size_pretty(pg_indexes_size(relid)) AS index_size,
  pg_size_pretty(pg_total_relation_size(relid) - pg_indexes_size(relid)) AS row_data_size
FROM pg_catalog.pg_statio_user_tables
WHERE relname = 'events';
```

### Parquet compression: 5–10x vs raw data

Parquet stores data column by column and compresses each column independently using the best encoding for that data type:

- **Low-cardinality strings** (event_type, device_type, plan, country): dictionary encoding compresses 10–50x — 20 distinct event types stored as integers, not repeated strings
- **Timestamps** (occurred_at, created_at): delta encoding compresses sequential timestamps 10–20x
- **UUIDs** (user_id, event_id): high-cardinality, minimal compression — 1.5–2x at best
- **Numeric metrics** (counts, amounts): 3–5x

For typical SaaS event data with a mix of these columns, expect **5–10x compression overall, averaging around 7x**.

**Worked example:**
- 250 GB Postgres → subtract indexes (~90 GB) → 160 GB row data
- Deflate MVCC bloat (25%) → ~120 GB actual data
- Apply 7x Parquet compression → **~17 GB in Iceberg**

Budget 15–25 GB for the initial 500M-row migration.

### Monthly growth estimate

Measure your actual bytes-per-row after the first batch ingestion:
```
parquet_bytes_per_row = total_Parquet_bytes / total_row_count
```

Then: `monthly_GB = parquet_bytes_per_row × 50_000_000 / 1_000_000_000`

For SaaS events with string/enum-heavy schemas, expect 50–200 bytes per row in Parquet. At 100 bytes/row: 50M rows × 100 bytes = **5 GB/month compressed**.

Projected total after 12 months: ~17 GB base + (12 × 5 GB) = **~77 GB**. Add 50% headroom for safety: budget **~115 GB**.

### Snappy vs Zstd

Iceberg's default codec is Snappy — fast compression and decompression, moderate compression ratio. Zstd gives **20–30% better compression than Snappy** at moderate CPU cost. For event data that you mostly write once and query later, switch to Zstd:

```sql
ALTER TABLE iceberg.analytics.events 
SET PROPERTIES write.parquet.compression-codec = 'zstd';
```

This applies to future writes; existing Parquet files aren't recompressed until you run `rewrite_data_files`.

### MinIO replication factor

MinIO on-premises typically uses erasure coding (default: EC:4+2 or EC:8+4), not simple replication. EC:4+2 gives roughly 1.5x raw disk overhead (not 2x or 3x like naive replication). For EC:4+2 with ~77 GB of data: budget ~115 GB of raw MinIO disk. Check your MinIO deployment configuration to confirm the erasure code ratio.

### The hidden storage trap: Iceberg snapshots

Without scheduled maintenance, old snapshots accumulate silently:
- Each `overwritePartitions()` run keeps the old files until `expire_snapshots` deletes them
- Without cleanup, storage can grow 20–30% per month beyond your actual data growth

Schedule weekly:
```sql
-- Run in Spark SQL
CALL iceberg.system.expire_snapshots(
  table => 'analytics.events',
  older_than => TIMESTAMP '2026-05-17 00:00:00',
  retain_last => 7
);
CALL iceberg.system.remove_orphan_files(table => 'analytics.events');
```

With maintenance scheduled, your storage growth tracks closely to data growth. Without it, you'll overshoot your budget within months.
