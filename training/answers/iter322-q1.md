# Answer to Q1: Storage Growth Estimation with Daily Updates (Iter 322)

## The Core Problem: Why Linear Isn't Always Right

Storage growth is **mostly linear**, but there's a hidden trap: **snapshot history**. Every time you UPDATE 10% of your rows, Iceberg keeps the old files around (in case you want to time-travel back). Those old files stay alive as long as you keep snapshots — and that's where storage can balloon.

## Piece 1: Live Data Growth

This is linear if your row count grows linearly.

**Formula:**
```
live_data_size = (rows_per_day × bytes_per_row) ÷ compression_ratio
```

**Worked example:**
- 1M rows/day (your event ingestion rate)
- 200 bytes/row average (typical SaaS event)
- 7x compression ratio (Zstd + low-cardinality columns)

Live data per day: `(1M × 200) ÷ 7 = ~28.6 MB/day`
Over 180 days (6 months): `28.6 MB × 180 = 5.1 GB` live data.

## Piece 2: Snapshot Overhead (The Trap)

This is where your 10% daily updates matter. **Every time you UPDATE, Iceberg rewrites the files containing those rows.** The old files don't disappear — they stay alive because older snapshots still reference them.

**Right mental model:**
```
snapshot_overhead = daily_rewritten_volume × retention_days
total_storage     = live_data_size + snapshot_overhead
```

NOT "overhead is 7% of live data" — that's wrong for heavily-updated tables.

**Your scenario — 10% daily updates:**
Say you have 100M total rows. Each day:
- You UPDATE 10M rows (10% of 100M)
- Iceberg rewrites the data files containing those rows: ~350 MB compressed
- **daily_rewritten_volume = 350 MB/day**

With 30-day snapshot retention:
```
snapshot_overhead = 350 MB × 30 days = 10.5 GB
```

If your live data is 1 GB: `total = 1 GB + 10.5 GB = 11.5 GB` (1,050% overhead)

## The 6-Month Spreadsheet Formula

| Parameter | Example | Formula |
|---|---|---|
| Live data per day | 28.6 MB | (rows × bytes_per_row) ÷ compression |
| Live data total | 5.1 GB | live_per_day × days_of_data_kept |
| Daily rewritten volume | 350 MB | (rows_updated × bytes_per_row) ÷ compression |
| Snapshot retention | 30 days | your retention policy |
| **Snapshot overhead** | **10.5 GB** | daily_rewritten × retention_days |
| **TOTAL STORAGE** | **15.6 GB** | live + snapshots |
| Headroom (20%) | 3.1 GB | for fragmentation, OS overhead |
| **MinIO requirement** | **~19 GB** | round up to next tier |

## Key Insight: It Scales With Retention, Not Calendar Time

If you only keep 7 days of snapshots instead of 30:
```
snapshot_overhead = 350 MB × 7 = 2.45 GB
total_storage     = 5.1 GB + 2.45 GB = 7.55 GB
```

Much smaller. **Snapshot cost depends on how long you keep history, not how long the data exists.**

## How to Measure Your Actual Bytes Per Row

Don't guess — query your existing Iceberg table:

```sql
SELECT
  SUM(file_size_in_bytes) * 1.0 / SUM(record_count) AS bytes_per_row_actual,
  SUM(record_count) AS total_rows
FROM iceberg.analytics."events$files";
```

Also measure your daily rewrite volume:

```sql
SELECT
  DATE_TRUNC('day', to_timestamp(committed_at/1000)) AS snapshot_day,
  COUNT(*) AS snapshots_per_day,
  SUM(summary['added-files-size']) AS bytes_added_per_day
FROM iceberg.analytics."events$snapshots"
WHERE summary['operation'] IN ('overwrite', 'delete')
GROUP BY 1
ORDER BY 1 DESC
LIMIT 7;
```

This gives you the real numbers to plug into the spreadsheet.

## Why 10% Daily Updates Doesn't Mean 10% Daily Storage Growth

Common mistake: "If I update 10% of rows, storage grows 10% per day." Wrong. You only add storage equal to the bytes rewritten, held for the snapshot window. If 10% of rows live in 35% of your data files (because Iceberg files aren't uniformly distributed), you're rewriting 35% of your storage per day — not 10%. The diagnostic queries above measure this directly.

## For Your 6-Month Plan

- Start with measured bytes-per-row from the `$files` metadata query
- Measure actual daily rewrite volume from the `$snapshots` query
- Apply: `total = live_data + (daily_rewrite × retention_days)`
- Add 20% headroom
- For a typical 1M-rows/day SaaS table with 10% daily updates and 30-day retention: plan for 15–25 GB over 6 months; drop retention to 7 days to cut snapshot overhead by ~75%
