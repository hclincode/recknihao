# Iter119 Q2 — Answer

**Question**: We ingest about 2 million event rows per day into Iceberg, but our MinIO storage usage is growing way faster than we expected — we're using almost 3x the storage we calculated based on raw data size. Our infra person says it might be related to how we're writing data, but we're not sure what to look at. We're using small frequent writes because our ingestion runs every 5 minutes. Is there something about how Iceberg writes files that would cause storage to balloon like this, and what should we actually do to fix it?

---

## Your 3x Storage Overgrowth: Why It Happens & How to Fix It

You're experiencing the most common Iceberg storage surprise — and the good news is it's fixable and preventable going forward. Let me explain what's actually happening, why your infra person's intuition is right, and what to do immediately.

### The Core Problem: How Iceberg Writes Create Storage Debt

Iceberg never modifies files in place. Every write (even your small 5-minute ingestion jobs) creates new Parquet files. Without maintenance, those files stay on MinIO forever because Iceberg snapshots keep referencing them.

Here's the math on your setup:

- **2 million rows/day ÷ 5-minute windows** = roughly 14 ingestion jobs per day
- **Each job creates at least one new Parquet file** per partition (often more if you have multiple partitions)
- **Each file is ~10–50 MB** for 2M/14 ≈ 143K rows per write
- **After 30 days, you have 420+ small files** just from raw ingestion

Then Iceberg creates:
- **One manifest file** per snapshot (lists which data files belong to that snapshot + column stats)
- **One snapshot** per write (a metadata pointer to the manifest)

After 30 days of 14 writes/day, you have 420+ snapshots, each still holding references to the old files.

### Why MinIO Usage Is 3x Raw Data Size

The 3x growth happens in layers:

1. **Raw ingestion creates many small files** — 2M rows × 30 days across 14 ingestions = hundreds of small Parquet files taking up much more space than they should (each file has overhead from the Parquet format itself, not row count).

2. **Old snapshots refuse to release old files** — When you next run maintenance and compact those 420 small files into, say, 5 bigger files, Iceberg writes the new 5 files **and keeps the 420 old ones** because the old 420 snapshots still reference them. MinIO now holds both: old small files + new big files. Storage grows, not shrinks.

3. **No snapshot expiry removes nothing** — The old snapshots (and the files they point to) persist indefinitely. You're paying MinIO storage for every historical version of every file from every compaction that ever ran.

**This is the 3x trap:** raw data = X GB, but with accumulating snapshots + compaction history, you end up with 2–4X GB.

### What You Need to Do Right Now (3 Steps)

#### Step 1: Audit Your Current Snapshot Backlog

Run this in Trino to see how many snapshots you're holding:

```sql
SELECT 
  COUNT(*) AS snapshot_count,
  MIN(committed_at) AS oldest_snapshot,
  MAX(committed_at) AS newest_snapshot
FROM iceberg.analytics."<your_table>$snapshots";
```

If the count is > 500 and the oldest snapshot is > 30 days old, you've confirmed the problem.

#### Step 2: Run Maintenance in This Exact Order

You need to run four Iceberg procedures. **Order matters** — running them out of sequence can leave storage on the table. Submit these via Spark (not Trino, because Spark has more flexible options for tight windows). Run once immediately, then schedule them going forward.

```sql
-- Spark SQL (submit via spark-submit or spark-sql)
-- Step 1: Compact small files into fewer, bigger ones (nightly).
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.your_table',
  options => map(
    'target-file-size-bytes', '268435456',  -- 256 MB target
    'min-input-files',        '5'           -- only compact if 5+ small files exist
  )
);

-- Step 2: Expire old snapshots (run weekly or immediately to clean up).
-- This says "forget snapshots older than 30 days; don't allow time-travel past that."
-- After expiry, files those old snapshots reference become eligible for deletion.
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.your_table',
  older_than  => current_timestamp - interval '30' day,
  retain_last => 10  -- always keep the last 10 snapshots as a safety net
);

-- Step 3: Remove orphan files (files no snapshot references).
-- This actually deletes the unreferenced files from MinIO.
CALL iceberg.system.remove_orphan_files(
  table      => 'analytics.your_table',
  older_than => current_timestamp - interval '3' day
);

-- Step 4: Rewrite manifest files (speeds up query planning).
CALL iceberg.system.rewrite_manifests(
  table => 'analytics.your_table'
);
```

**Critical caveat:** After step 1 (compaction), MinIO usage will temporarily spike — you're writing new big files while old small files are still there. It's only after steps 2–4 that storage drops visibly. Don't panic if the graph looks worse after just compaction.

#### Step 3: Schedule This as Routine Maintenance

Going forward, set up a recurring schedule (in Airflow, Kubernetes CronJob, or whatever scheduler you use):

- **Nightly (4 AM, after ingestion finishes):** `rewrite_data_files` on each table
- **Weekly (Sunday 3 AM, when ingestion is paused):** 
  1. `expire_snapshots`
  2. `remove_orphan_files`  
  3. `rewrite_manifests`

This prevents the 3x problem from building up again.

### Why Your 5-Minute Writes Cause This Specifically

Every 5-minute ingestion job is a micro-batch. At 14 jobs/day:

- **With maintenance:** each file stays ~256 MB, compaction merges them nightly, snapshots expire weekly → storage ≈ 1–1.5x raw data.
- **Without maintenance (your current state):** each file stays small, old snapshots never expire, you accumulate 420+ small files + 420+ snapshots → storage ≈ 3–4x raw data.

If you were doing one daily batch instead, the problem wouldn't hit as hard (fewer files per day), but the answer is the same: schedule maintenance.

### The Two Hidden Metrics to Watch

Once you've cleaned up:

1. **Snapshot count** — keep this under 50–100. If it climbs back over 500, your `expire_snapshots` isn't running.
2. **File count per partition** — run this query in Trino to see:
   ```sql
   SELECT 
     COUNT(*) AS file_count,
     SUM(file_size_in_bytes) / 1024 / 1024 / 1024 AS total_gb
   FROM iceberg.analytics."<your_table>$files";
   ```
   You want < 100 files for a table with < 100 GB data. If you see > 1,000 files, compaction isn't running or is too infrequent.

### To Summarize

- **Immediate fix:** run the four-step maintenance sequence (compaction → expire snapshots → remove orphan files → rewrite manifests) on your table today.
- **Ongoing fix:** schedule those four steps as recurring jobs: compaction nightly, the other three weekly.
- **Expected result:** MinIO usage should drop from 3x back to 1.2–1.5x raw data size within a few hours (after step 2; steps 3–4 are metadata cleanup).

The 3x overgrowth is not a bug in Iceberg — it's a design consequence of immutable files and snapshot retention. Once you schedule maintenance, this problem goes away and stays away. Your storage will track your actual data growth, not snapshot debt.
