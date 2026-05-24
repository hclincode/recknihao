# Iter53 Q2 Answer — Measuring Bytes-Per-Event for Storage Budget Planning

## The short answer

Query Iceberg's `$files` metadata table to get `file_size_in_bytes` and `record_count` per Parquet file, then divide total bytes by total rows. This gives you bytes-per-row on actual compressed Parquet data. Use it to forecast: **monthly_GB = (bytes_per_row × monthly_row_count) ÷ 1,000,000,000**.

---

## Where to find bytes-per-event: the `$files` metadata table

Iceberg exposes a built-in `$files` metadata table — one row per Parquet file — with `file_size_in_bytes` and `record_count`. Query it in Trino:

```sql
SELECT
  SUM(file_size_in_bytes)                               AS total_bytes,
  SUM(record_count)                                     AS total_rows,
  SUM(file_size_in_bytes) * 1.0 / SUM(record_count)   AS bytes_per_row
FROM iceberg.analytics."events$files";
```

The double-quotes around `"events$files"` are required — Trino needs them to treat `$files` as part of the table name, not a variable.

`bytes_per_row` is the average on-disk size per row **after Parquet compression** — what you actually use on MinIO. For typical SaaS events, expect 5–200 bytes/row depending on your schema.

**Measure per event type** since page views compress differently from rich error logs:

```sql
SELECT
  event_type,
  SUM(file_size_in_bytes) * 1.0 / SUM(record_count) AS bytes_per_row,
  SUM(record_count)                                  AS total_rows
FROM iceberg.analytics."events$files"
GROUP BY event_type
ORDER BY bytes_per_row DESC;
```

---

## Why the number varies by event type

Parquet compression is per-column. The ratio depends on what's in your schema:

| Column type | Compression | Reason |
|---|---|---|
| `event_type`, `country`, `plan_type` | 10–50x | Dictionary encoding: ~10 distinct values stored once, then 1-byte codes |
| Timestamps (`occurred_at`) | 10–20x | Delta encoding: small deltas between sorted timestamps |
| UUIDs, email addresses | 1.5–2x | High cardinality — no patterns to compress |
| JSON blobs (`properties`) | 2–3x | Structure not exploited; treated as opaque text |

A page view event (mostly enum-like fields) might be 5–8 bytes/row. An API error log (with stack traces and request bodies) might be 100–200 bytes/row. Use the per-event-type measurement, not a single average.

---

## The forecasting formula

```
monthly_GB = (bytes_per_row × monthly_row_count) / 1,000,000,000
```

**Worked example:** A new enterprise customer sends 50 million page view events per month. Your measured `bytes_per_row` for page views is 6.2 bytes.

```
50,000,000 × 6.2 / 1,000,000,000 = 0.31 GB/month = ~310 MB/month
```

Annual: ~3.7 GB for that customer's page view events. Multiply across all event types and all projected customers for your spreadsheet.

---

## Add a 20–30% buffer

The `$files` measurement is real data, but you need headroom for:

1. **Small files before compaction** — between ingestion and the nightly `rewrite_data_files` run, small files accumulate. They'll compress better after compaction, but occupy more space in the interim.
2. **Metadata overhead** — Iceberg manifest files and snapshot metadata add ~1–3% on top of Parquet size.
3. **New customer data variation** — a new customer's schema or data distribution may compress differently from your average. Add 10% safety margin.

**Rule of thumb:** use `bytes_per_row × 1.25` in your spreadsheet model.

---

## MinIO erasure coding: 1.5× raw disk overhead

On-prem MinIO uses erasure coding — typically EC:4+2 or similar — not naive replication. EC:4+2 means 4 data blocks + 2 parity blocks: raw disk = 1.5× usable data (not 2× or 3×). Budget accordingly:

```
raw_disk_needed = forecasted_GB × 1.5
```

---

## Check your compression codec

Your production stack runs Iceberg 1.5.2, which defaults to **Zstd** compression (changed from Snappy in Iceberg 1.4.0). Zstd gives 20–30% better compression than Snappy. Verify your table is using it:

```sql
SHOW CREATE TABLE iceberg.analytics.events;
-- Look for: 'write.parquet.compression-codec' = 'zstd'
```

If it shows Snappy (e.g., table was created before Iceberg 1.4.0 with an older cluster), you can switch future writes to Zstd:

```sql
-- Trino syntax:
ALTER TABLE iceberg.analytics.events
  SET PROPERTIES "write.parquet.compression-codec" = 'zstd';
```

This applies only to new Parquet files. Old Snappy files stay as-is. To retroactively compress existing files with Zstd, run a recompaction job — but weigh the Spark CPU cost against the disk savings.

---

## Your spreadsheet checklist

- [ ] Run `$files` query per event type → get `bytes_per_row` baseline
- [ ] For each event type: `projected_monthly_rows × bytes_per_row × 1.25 / 1e9 = monthly_GB`
- [ ] Sum across all event types and all projected customers
- [ ] Multiply by 12 for annual growth projection
- [ ] Apply 1.5× for MinIO erasure coding overhead → this is your **raw disk needed**
- [ ] Add 20% filesystem headroom → this is your **hardware budget ask**
- [ ] Schedule `expire_snapshots` weekly to prevent snapshot accumulation from doubling your storage
