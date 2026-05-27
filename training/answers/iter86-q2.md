# Iter86 Q2 — Answer

**Question**: Partitioning looks correct but queries still slow. Suspect too-small files from streaming/hourly writes. How to diagnose with Iceberg metadata, and what's the fix?

---

## Answer

You've correctly intuited the problem: streaming writes and hourly batch jobs create hundreds or thousands of tiny files per day, and even good partitioning can't help if the files themselves are too small. Here's how to diagnose it and fix it.

### How to Check Your File Sizes

Iceberg stores a metadata table called `$files` that lists every data file in the current snapshot, including file sizes. Run this diagnostic in Trino:

```sql
SELECT 
  CASE 
    WHEN file_size_in_bytes < 1024*1024*10 THEN '<10MB'
    WHEN file_size_in_bytes < 1024*1024*64 THEN '10-64MB'
    WHEN file_size_in_bytes < 1024*1024*128 THEN '64-128MB'
    WHEN file_size_in_bytes < 1024*1024*256 THEN '128-256MB'
    WHEN file_size_in_bytes < 1024*1024*512 THEN '256-512MB'
    ELSE '>512MB'
  END AS size_bucket,
  COUNT(*) AS file_count,
  ROUND(SUM(file_size_in_bytes) / 1024 / 1024 / 1024, 1) AS total_gb
FROM iceberg.analytics.user_events$files
GROUP BY 1
ORDER BY MIN(file_size_in_bytes);
```

If you see thousands of files in the `<10MB` or `<64MB` buckets, you've confirmed the problem. You can also spot-check the smallest files directly:

```sql
SELECT 
  file_path,
  ROUND(file_size_in_bytes / 1024 / 1024, 1) AS size_mb,
  partition
FROM iceberg.analytics.user_events$files
ORDER BY file_size_in_bytes ASC
LIMIT 50;
```

### Why 128–256 MB Is the Sweet Spot

Every Parquet file in MinIO has fixed overhead when Trino reads it — roughly 10–50 milliseconds per file just to open it, read its footer, and decode column statistics. This happens *before any data is read*.

If you have 10,000 tiny files covering one month across all tenants, a query touching that month spends 100–500 seconds just on file opens. On 100 compacted 256 MB files instead, file-open cost drops to 1–5 seconds — the rest is actual data scanning.

The 128–256 MB range is the sweet spot:
- **128 MB**: good for highly selective queries — keeps file-open overhead cheap relative to data read.
- **256 MB**: the standard default. Big enough that 50ms file-open overhead is noise; small enough for parallelism (one file per Spark/Trino worker task).
- **Above 512 MB**: hurts parallelism — fewer files than workers means some sit idle.

Your `(tenant_id, month)` partition scheme is solid — partitioning controls *which* files a query opens, not *how fast* opening those files is. Good partitioning + tiny files means you open fewer files but they still open slowly. Compaction fixes the file-size dimension.

### The Fix: `rewrite_data_files` (Compaction)

The Iceberg procedure `rewrite_data_files` reads all the small files in each partition and rewrites them as larger compacted Parquet files:

```sql
-- Run in Spark (spark-submit or spark-sql) — NOT in Trino
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.user_events',
  options => map(
    'target-file-size-bytes', '268435456',  -- 256 MB target
    'min-input-files',        '5'           -- only compact partitions with 5+ small files
  )
);
```

**What it does:**
- Reads each partition's small files and merges them into new Parquet files targeting ~256 MB.
- Creates a new Iceberg snapshot pointing to the compacted files.
- The old small files are still on MinIO but only referenced by older snapshots — invisible to new queries.

**Important:** compaction temporarily increases storage because both old small files and new large files coexist until you expire old snapshots. Storage drops after:

```sql
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.user_events',
  older_than  => current_timestamp - interval '30' day,
  retain_last => 10
);
```

### Scheduling Compaction

For high-frequency streaming or hourly writes, run compaction nightly:

- Ingestion finishes at 2 AM.
- `rewrite_data_files` runs at 4 AM (after ingestion is complete — avoids conflict with active writes).
- `expire_snapshots` runs right after, or in a separate weekly maintenance window.

For lower-volume tables, weekly compaction is sufficient.

### Verifying the Fix

After compaction and snapshot expiry, re-run the distribution query. You should see:
- Most files in the 128–256 MB bucket.
- File count reduced by 5–50x depending on how small the originals were.
- Query planning time in the Trino UI drops noticeably — often from 10+ seconds to under 1 second for the file-open phase.

### One More Diagnostic

If `EXPLAIN ANALYZE` on your slow query shows a very high "Physical input data size" relative to the rows returned, that's another signal. High physical input with low row count = reading too many files unnecessarily, either from missing partition pruning or tiny-file overhead. The file-size distribution query above will tell you which one it is.
