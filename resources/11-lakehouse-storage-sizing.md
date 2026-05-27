# Storage Sizing and Cost for a SaaS Lakehouse

> **Production note:** Storage is on bare-metal MinIO (on-prem). There's no per-GB cloud bill, but you still need to size disks, plan growth, and budget Trino compute. This file gives you the back-of-the-envelope math.

---

## Quick answer (TL;DR)

- **Sizing formula:** `raw row bytes × row count ÷ compression ratio = on-disk Parquet size`.
- Typical Parquet compression for SaaS event data is **5–10x** (sometimes 20x+ for low-cardinality columns).
- A 100M-row event table with ~200 bytes/row raw → ~2–4 GB compressed. Easily fits on a single MinIO node.
- Iceberg metadata adds **~1–3%** overhead — negligible. Snapshot retention is the real growth driver — schedule `expire_snapshots` (Iceberg's `history.expire.max-snapshot-age-ms` default is 5 days, Trino's `iceberg.expire-snapshots.min-retention` floor is 7 days; many teams pick 30 days as an operator preference for a comfortable rollback window).
- On-prem cost is hardware + power, not per-GB. Size disks for **peak + 20% headroom**, plan a refresh when you hit 70% capacity.

---

## The sizing formula

```
on-disk size = (avg raw bytes per row × number of rows) ÷ compression ratio
```

### Worked example: `user_events`

- 10 columns, average raw size 200 bytes per row.
  - `event_id` (UUID): 36 bytes
  - `tenant_id` (short string): 10 bytes
  - `user_id` (UUID): 36 bytes
  - `event_name` (short string): 15 bytes
  - `occurred_at` (timestamp): 8 bytes
  - `plan_type` (short string): 10 bytes
  - `country` (2-char): 2 bytes
  - `properties` (small map): ~80 bytes
  - overhead/padding: ~3 bytes
  - **Total: ~200 bytes/row** raw.
- 100M rows/year (about 275K events/day — average B2B SaaS).
- **Raw size:** 200 B × 100M = 20 GB/year uncompressed.
- **Parquet compressed (~7x):** ~3 GB/year on MinIO.
- At 80 tenants with even distribution: ~37 MB/tenant/year. (In reality the largest 20% of tenants will dominate.)

### Worked example: `feature_usage`

- 10 columns, ~150 bytes/row raw.
- 300M rows/year (every feature interaction tracked).
- Raw: 45 GB. Compressed (~8x): ~6 GB/year.

### Worked example: `subscription_changes`

- 12 columns, ~120 bytes/row raw.
- Low volume — maybe 50,000 rows/year for an 80-tenant SaaS.
- Raw: 6 MB. Compressed: ~1 MB/year. (Yes, megabytes.)

**Total lakehouse footprint, year 1:** Sum of fact tables + dimensions + rollups ≈ **10–20 GB compressed**. Three years out: well under 100 GB unless you're capturing very rich events.

---

## Migrating from Postgres — why Postgres on-disk bytes are the wrong baseline

If you're sizing a lakehouse migration and you start with the number from `pg_total_relation_size`, you will overestimate the source data size by 30–50% and get a wildly wrong Parquet size estimate. This mistake has one predictable shape: "our 200 GB Postgres database will become 20–40 GB in the lakehouse" (dividing 200 GB by a 5–10x compression ratio directly) — but the actual result is typically 13–30 GB, because the 200 GB contains a large amount of data that doesn't exist in the rows being migrated.

### What pg_total_relation_size actually includes

`pg_total_relation_size(table)` is the sum of:
- **Actual row data** — the heap pages containing your rows (what you're migrating)
- **Index storage** — B-tree indexes, partial indexes, GIN indexes for JSONB. These are often 30–50% of total table size for heavily indexed Postgres tables, and they do not transfer to Parquet (Parquet uses columnar stats + partition pruning instead of indexes)
- **TOAST storage** — oversize column values (long TEXT, JSONB blobs) stored out-of-line. This does transfer, but it's already counted in "row data" semantically
- **Dead tuples** — rows deleted by `DELETE` or `UPDATE` that `VACUUM` hasn't reclaimed yet. These do not exist in the migrated data
- **Page bloat** — free space within heap pages left by autovacuum. Parquet packs rows with no padding

**The practical rule:** Postgres 200 GB on-disk is typically 100–150 GB of actual row data that would appear in a migration.

### The diagnostic query (run this first)

Before estimating Parquet size, run this in Postgres to separate row data from index overhead:

```sql
SELECT
  relname AS table_name,
  pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
  pg_size_pretty(pg_indexes_size(relid)) AS index_size,
  pg_size_pretty(pg_total_relation_size(relid) - pg_indexes_size(relid)) AS row_data_size
FROM pg_catalog.pg_statio_user_tables
ORDER BY pg_total_relation_size(relid) DESC;
```

This gives you `row_data_size` per table — the heap size including TOAST but excluding indexes.

### The two-step adjustment

Once you have `row_data_size` from the query above:

1. **Subtract indexes** — already done by the query (`total_size - index_size = row_data_size`).
2. **Divide by 1.3–1.5 for bloat** — dead tuples and page fragmentation typically inflate the heap by 30–50% on a live Postgres instance that runs UPDATEs/DELETEs. A busy table gets bloated faster; a read-heavy table may be closer to 1.1x.

After those two steps, apply the normal Parquet compression ratio (5–10x for SaaS event data).

**Worked example — 200 GB Postgres database:**

| Step | Calculation | Result |
|---|---|---|
| Start: total on-disk | — | 200 GB |
| Subtract indexes (assume 30% of total) | 200 × 0.70 | 140 GB row data |
| Deflate for bloat (÷ 1.3) | 140 ÷ 1.3 | ~108 GB actual rows |
| Apply Parquet compression (÷ 7x) | 108 ÷ 7 | ~15 GB in the lakehouse |

Applying 5–10x compression directly to 200 GB gives 20–40 GB — off by 25–75% because the starting baseline was wrong.

### Fallback heuristic: measure before estimating

If you don't want to do the math, export a representative sample of 100,000 rows to Parquet (using Spark or DuckDB) and measure the actual file size:

```python
# Export sample to Parquet, measure ratio
df = spark.read.jdbc(url=PG_URL, table="(SELECT * FROM events LIMIT 100000) t", properties=PG_PROPS)
df.write.parquet("s3a://lakehouse/sizing-sample/events/")
# Compare: spark.read.parquet(...).count() / actual bytes on MinIO
```

This gives you the real compression ratio for your specific data distribution — often more accurate than any estimate.

### Measuring bytes-per-row from existing Iceberg data (the `$files` approach)

Once you have data in Iceberg, the `$files` metadata table gives you actual on-disk file sizes and row counts — no estimation required. Query it in Trino:

```sql
-- Overall bytes-per-row across the entire table
SELECT
  SUM(file_size_in_bytes)                              AS total_bytes,
  SUM(record_count)                                    AS total_rows,
  SUM(file_size_in_bytes) * 1.0 / SUM(record_count)  AS bytes_per_row
FROM iceberg.analytics."events$files";
```

The double-quotes around `"events$files"` are required — Trino parses the `$` as a name separator otherwise.

**Important: `$files` is FILE-level metadata, not row-level.** It has `file_path`, `file_size_in_bytes`, `record_count`, `file_format`, and `partition` — but NOT row-level columns like `event_type`, `user_id`, or `tenant_id`. Querying `GROUP BY event_type` on `$files` will fail with "Column 'event_type' cannot be resolved".

**To get per-event-type bytes-per-row, use one of these approaches:**

**Option A — If the table is partitioned by `event_type`:** the `partition` column in `$files` exposes partition key values. Use it to group:

```sql
-- Works when the table is partitioned by event_type
SELECT
  partition.event_type                                  AS event_type,
  SUM(file_size_in_bytes) * 1.0 / SUM(record_count)   AS bytes_per_row,
  SUM(record_count)                                     AS total_rows
FROM iceberg.analytics."events$files"
GROUP BY partition.event_type
ORDER BY bytes_per_row DESC;
```

**Option B — If the table is NOT partitioned by `event_type`:** sample from the base table and measure compressed size via a Spark job:

```python
# Spark: write a sample per event_type and check MinIO file sizes
for event_type in ["page_view", "api_call", "feature_usage"]:
    df = spark.read.table("iceberg.analytics.events") \
               .filter(f"event_type = '{event_type}'") \
               .limit(100_000)
    df.write.parquet(f"s3a://lakehouse/sizing-sample/{event_type}/")
    # Then check actual bytes on MinIO to compute bytes_per_row
```

**Option C — For a quick approximation without per-type breakdown:** run the overall `$files` query on a recent date partition (1-2 weeks of data). The overall bytes-per-row is a reasonable starting point; then apply a multiplier for known high-cardinality event types (e.g., events with raw URLs or JSON blobs will be 3–5x larger than enum-only events).

---

## Compression estimates by column type

Parquet compression depends heavily on the column's data shape. Use this table to refine sizing estimates per column.

| Column type | Typical compression ratio | Why |
|---|---|---|
| Booleans | 50–100x | One bit needed per row; rest is repetition |
| Low-cardinality string (`event_name`, `plan_type`, `country`) | 10–50x | Dictionary encoding — store ~10 distinct values once, then 1-byte codes |
| Timestamps (sorted by partition) | 10–20x | Delta encoding — small deltas pack into few bits |
| Integer IDs (sequential) | 5–10x | Delta encoding |
| Integer IDs (random) | 2–4x | Random distribution defeats most compression |
| High-cardinality strings (UUID, email) | 1.5–2x | Few patterns to compress; mostly LZ4/Snappy on raw bytes |
| JSON blobs | 2–3x | Structure isn't exploited; treat as opaque text |
| Floats (random) | 1.2–1.5x | Mantissas look random to compressors |

### Default Parquet compression codec

**Iceberg 1.4.0 and later (including 1.5.x in production) use Zstd as the default Parquet write codec — not Snappy.** Zstd gives 20–30% better compression than Snappy at moderate CPU cost. For event data that is written once and queried later, Zstd is the right default.

You can verify and change the codec per table:

```sql
-- Check current codec for a table
SHOW CREATE TABLE iceberg.analytics.events;  -- look for 'compression-codec' in the properties

-- Change to Zstd (already the default in 1.5.x, but explicit is safer)
-- Spark SQL:
ALTER TABLE iceberg.analytics.events
  SET TBLPROPERTIES ('write.parquet.compression-codec' = 'zstd');

-- Trino:
ALTER TABLE iceberg.analytics.events
  SET PROPERTIES "write.parquet.compression-codec" = 'zstd';
```

This applies to **future writes only**. Existing Parquet files keep their original codec until you run `CALL iceberg.system.rewrite_data_files(table => 'analytics.events')` (in Spark), which rewrites files with the new codec.

> **Note for Iceberg < 1.4.0:** Snappy was the default before 1.4.0. If you're on an older version, the Zstd switch is worth applying explicitly.

### Practical implications
- **Promote enum-like strings to top-level columns.** A `MAP<VARCHAR,VARCHAR>` storing `"plan_type"="pro"` once per row is much bigger than a `plan_type VARCHAR` column with dictionary encoding.
- **Store UUIDs as `VARCHAR` only if you need to.** A binary `UUID` type halves storage. If you store many high-cardinality UUIDs, that adds up.
- **Don't shove everything into JSON.** A JSON blob with 20 fields will be 5–10x larger than the same 20 fields as top-level Parquet columns.

---

## Growth projection

### Linear growth (mature product)
If you add ~5% new tenants per month and existing tenants don't grow much:
- Year-1: 3 GB.
- Year-3: ~5 GB (compounding at 5%/month × 36 months = ~6x).

### Compound growth (growing product)
If events/day grows 20%/month (you're in early-stage hyper-growth):
- Each year multiplies storage by roughly 12x.
- Year-1: 3 GB. Year-2: 36 GB. Year-3: 430 GB.
- This is when you need to think hard about retention (do you really need raw events older than 18 months?) and rollup tables.

### Realistic projection
For a typical B2B SaaS in steady-state at 80 customers:
- **Year 1**: 20–50 GB total lakehouse footprint.
- **Year 3**: 100–300 GB with all fact tables + rollups + dimensions.
- **Year 5**: 500 GB–1 TB if growth continues.

Even at 1 TB, a single MinIO node with a few disks is sufficient. Lakehouses scale to petabytes, but most SaaS workloads never get close.

### Iceberg metadata overhead
- Manifest files: ~1 KB per data file.
- Snapshot files: ~10 KB per snapshot.
- Total metadata: typically **1–3% of data size**. Negligible unless you have millions of tiny files (in which case fix the small-files problem first — see `10-lakehouse-partitioning.md`).

### Snapshot accumulation — the actual storage trap
Time-travel snapshots reference data files. Without `expire_snapshots`, every compaction *adds* files (the new big ones) while keeping the old ones around (because snapshots still reference them).

Without expiry, a 100 GB table can balloon to 300+ GB in a year just from snapshot accumulation. **Always schedule `expire_snapshots`** — a common operator setting is "retain 30 days of history, keep last 10 snapshots, delete the rest." Iceberg's own default for `history.expire.max-snapshot-age-ms` is 5 days, and Trino enforces a 7-day minimum-retention floor (`iceberg.expire-snapshots.min-retention`); 30 days is a typical operator override for a comfortable rollback window, not a documented default of either system.

---

## MinIO capacity planning (on-prem)

### The mental model
- Storage cost is **hardware**, not per-GB-month.
- A 4-disk MinIO node with 4 TB drives = ~12 TB usable (after erasure coding overhead).
- That's enough for most SaaS lakehouses for many years.

### Sizing rules
1. **Estimate your year-3 data size** (use the sizing formula above).
2. **Multiply by 2** to cover snapshot accumulation and growth surprise.
3. **Add 20% headroom** on the disks (filesystem fragmentation, OS overhead).
4. **Plan a hardware refresh** when you cross 70% capacity.

### Example
- Year-3 projected data: 300 GB.
- × 2 (snapshots + growth surprise): 600 GB.
- + 20% headroom: 720 GB.
- A 1 TB MinIO node has 280 GB to spare — plenty.

### MinIO erasure coding

MinIO's EC:4 means "4 parity drives per erasure set." The **usable percentage depends on the erasure set size** — it is NOT a fixed 50%. Sizing advice that says "plan 2× raw" only applies to 8-drive sets.

| Erasure set size | EC:4 usable % | Rule of thumb |
|---|---|---|
| 8 drives | 50% | Plan 2× raw |
| 12 drives | ~67% | Plan 1.5× raw |
| 16 drives | ~75% | Plan 1.3× raw |

Pick the row that matches your actual erasure set configuration. For example, 1 TB usable on a 12-drive EC:4 set = ~1.5 TB raw across drives, not 2 TB. Misapplying the 8-drive rule to a 16-drive deployment will over-provision storage by ~50%.

### What grows fastest
- **Raw event tables** — direct function of user activity.
- **Snapshots/orphan files** — if maintenance isn't scheduled.
- **Failed Spark jobs leaving orphans** — periodic `remove_orphan_files` cleans these up.

---

## Snapshot Management Commands

The full Spark procedure syntax for Iceberg 1.5.2 maintenance operations. Run these on a schedule (Airflow, cron, or a dedicated maintenance Spark job).

```sql
-- Expire old snapshots: drops snapshots older than the cutoff, but always retains at least N most recent.
-- Required to reclaim storage from old data files no longer referenced by any retained snapshot.
CALL catalog.system.expire_snapshots(
  table       => 'analytics.events',
  older_than  => TIMESTAMP '2024-01-01 00:00:00',
  retain_last => 5
);

-- Compact small files: rewrites the table's data files to target file size (default 512 MB).
-- Run after streaming ingest or any workload that produces many small files.
CALL catalog.system.rewrite_data_files(
  table => 'analytics.events'
);

-- Remove orphan files: deletes data/metadata files in the table's storage location that are
-- not referenced by any snapshot. Catches files left behind by failed Spark jobs.
CALL catalog.system.remove_orphan_files(
  table      => 'analytics.events',
  older_than => TIMESTAMP '2024-01-01 00:00:00'
);
```

Replace `catalog` with your actual catalog name (e.g., `iceberg`, `prod`, etc.) and use named arguments (`table => '...'`) — they are required for Iceberg's Spark procedures.

A typical schedule:
- `rewrite_data_files` — daily (hourly for streaming sinks; see `14-real-time-vs-batch.md`).
- `expire_snapshots` — daily, with `older_than = current_timestamp - INTERVAL 30 DAYS` and `retain_last = 10`.
- `remove_orphan_files` — weekly, with `older_than = current_timestamp - INTERVAL 7 DAYS` to avoid racing with in-flight writes.

---

## Query cost (Trino compute)

Storage is one cost; compute is the other. On-prem you pay in cluster CPU/memory, not per-query dollars.

### What drives Trino query cost
- **Bytes scanned**: well-partitioned queries read GBs, not TBs.
- **Worker count**: more workers = more parallelism = faster queries (up to a point — small files limit parallelism).
- **JOIN size**: small dimension JOINs are cheap (broadcast). Big-fact-to-big-fact JOINs are expensive (shuffle).
- **Aggregation cardinality**: `GROUP BY` with millions of groups stresses memory.

### Rough rule of thumb
On a 4-node Trino cluster (16 cores, 64 GB RAM each):
- Scanning **1 GB** of well-laid-out Parquet → sub-second.
- Scanning **100 GB** with partition pruning → ~5–15 seconds.
- Scanning **1 TB** with good filters → ~30–90 seconds.
- A full TB scan with no filters → minutes, possibly with OOMs if you don't have spill enabled.

### The 10x rule
**Every 10x data growth ≈ 10x query time, unless you re-partition or add nodes.** Partition pruning is the primary lever — well-chosen partitions can absorb 100x data growth before queries slow down.

### Practical tips to keep Trino fast as data grows
1. **Always filter by the partition column** (`occurred_at >= ...`). This is the single biggest performance win.
2. **Use `approx_distinct` instead of `COUNT(DISTINCT)`** when 2% error is OK (HyperLogLog — 100x less memory).
3. **Pre-aggregate into rollup tables** for high-traffic dashboards.
4. **Compact small files** — a query that opens 10,000 files spends most of its time on file-open overhead.
5. **Add Trino workers** before sharding tables; horizontal scaling is cheap and easy in Kubernetes.

---

## Cost-saving tactics (on-prem, no cloud bill)

Even without a per-GB invoice, hardware capacity is finite. These tactics keep you off the next hardware purchase order.

### 1. Tiered retention
- Raw `user_events` for 18 months. Older → drop, or copy to a cold archive bucket on MinIO.
- Rollup tables (`daily_user_activity`) kept indefinitely — they're tiny.

### 2. Drop high-volume noise
- Heartbeat events (`session_ping` every 30s) are massive and rarely useful. Sample at 1/10 or drop after aggregating to rollups.

### 3. Promote frequently-queried JSON keys to columns
- Each promoted key: 5–10x less storage *and* makes queries faster.

### 4. Tune `target-file-size-bytes` per table
- High-volume tables: 512 MB files (fewer files = less metadata).
- Low-volume tables: 128 MB files (better parallelism per scan).

### 5. Use `approx_distinct` / approximate aggregations in dashboards
- Saves memory; lets a smaller Trino cluster handle more concurrent dashboards.

---

## Decision checklist before creating a new fact table

Before adding a table, work through:

- [ ] **Raw row size** — what's the average byte size per row?
- [ ] **Row volume** — how many rows/day, /year?
- [ ] **Expected compression** — mostly low-cardinality (high compression) or UUIDs (low compression)?
- [ ] **Partition strategy** — by day? by tenant? both? (See `10-lakehouse-partitioning.md`.)
- [ ] **Retention policy** — how long do you keep raw rows?
- [ ] **Rollup needed?** — if daily volume > ~10M rows, plan a rollup table.
- [ ] **Maintenance jobs scheduled** — `rewrite_data_files`, `expire_snapshots`.

Going through this list catches the surprise growth and surprise cost before they bite.

---

## Key terms

| Term | Meaning |
|---|---|
| **Compression ratio** | Raw bytes ÷ on-disk bytes after Parquet encoding + Snappy/ZSTD. |
| **Dictionary encoding** | Storing low-cardinality column values once, with small integer codes per row. |
| **Delta encoding** | Storing differences between sorted values (timestamps, sequential IDs) instead of full values. |
| **Erasure coding** | MinIO's redundancy scheme — splits data across disks with parity for fault tolerance. |
| **Snapshot retention** | How long Iceberg keeps old table versions; controlled by `expire_snapshots`. |
| **Rollup table** | Pre-aggregated summary table built nightly from raw events. |
| **Cold tier** | Lower-cost storage for old, rarely-queried data; on MinIO this might just be slower disks. |
| **Headroom** | Free disk capacity kept as a buffer; usually 20–30%. |
| **approx_distinct** | Trino function using HyperLogLog — fast, low-memory count-distinct with ~2% error. |
