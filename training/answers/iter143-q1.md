# Iter143 Q1 — Answer

**Question**: "We've been running our setup for about six months now and I just looked at our MinIO storage usage — it's way bigger than I expected. We've definitely deleted rows and dropped old data from our tables through the normal process, but the storage keeps climbing. I don't understand why. Shouldn't deleting data make storage go down?"

---

## Why Deleted Data Doesn't Immediately Free MinIO Storage

You're seeing storage grow despite deleting rows because Iceberg is built on **immutable Parquet files** — once a file is written, it never changes. When you delete rows, Iceberg doesn't rewrite the files right away; instead, it marks the rows as deleted but keeps the physical files on MinIO. The old files stay on disk because prior snapshots (point-in-time versions of your table) still reference them. This is a feature for time-travel and rollback — but it means you need **maintenance** to actually reclaim the storage.

Think of it like Git: when you delete a file and commit, the commit object references the new state, but Git keeps the old commit around for history. Until you run garbage collection and repack the repository, the old objects sit around taking disk space.

---

## The Three-Step Maintenance Sequence That Actually Reclaims Storage

Storage only shrinks after you run **three operations in this exact order**:

### 1. Compaction (nightly)

This is the `rewrite_data_files` operation. It reads all your small Parquet files in each partition, merges them into fewer, bigger files (~256 MB each), and applies any pending deletes.

In Trino 467:
```sql
ALTER TABLE iceberg.analytics.events EXECUTE optimize(file_size_threshold => '128MB');
```

In Spark (for more tuning options):
```sql
-- Spark SQL only
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.events',
  options => map(
    'target-file-size-bytes', '268435456',  -- 256 MB
    'min-input-files', '5'
  )
);
```

**Important:** Compaction **writes new files** but doesn't delete the old ones yet. After this runs, MinIO usage often **goes UP**, not down — the old small files are still there because the previous snapshot still references them.

### 2. Expire snapshots (weekly)

This removes old snapshot metadata, so the data files only those snapshots referenced become eligible for deletion.

In Trino 467:
```sql
ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '30d');
```

In Spark:
```sql
-- Spark SQL only
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.events',
  older_than  => current_timestamp - interval '30' day,
  retain_last => 10
);
```

After this runs, files that **no current snapshot** references are now orphaned and can be safely deleted.

### 3. Remove orphan files (weekly)

This scans MinIO for any Parquet file that no current snapshot references and deletes it.

In Trino 467:
```sql
ALTER TABLE iceberg.analytics.events EXECUTE remove_orphan_files(retention_threshold => '7d');
```

In Spark:
```sql
-- Spark SQL only
CALL iceberg.system.remove_orphan_files(
  table      => 'analytics.events',
  older_than => current_timestamp - interval '7' day
);
```

**Only after all three steps does MinIO storage actually shrink.** If you ran compaction last night and storage still grew, that's expected — you're waiting for `expire_snapshots` and `remove_orphan_files` to complete the cycle.

---

## The 7-Day Minimum Retention Floor in Trino 467

Trino enforces a hard minimum of **7 days** for both `expire_snapshots` and `remove_orphan_files`. You cannot pass `retention_threshold => '3d'` or anything below 7 days — Trino will reject the call with an error.

```sql
-- This FAILS in Trino 467 — below the 7-day floor
ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '3d');
-- Error: Cannot expire snapshots younger than 7 days

-- This works — 7d or higher
ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '30d');
```

The floor is set via `iceberg.expire-snapshots.min-retention` and `iceberg.remove-orphan-files.min-retention` in your Trino coordinator config. For routine maintenance, stick with 7–30 days. If you need to purge data younger than 7 days (e.g., GDPR right-to-erasure), run the operation from **Spark instead** — Spark has no minimum-retention floor.

---

## Checking Current Storage State with Metadata Tables

Before running maintenance, check how much data you're actually storing and how many old snapshots you have:

### Check total data files and bytes
```sql
-- Query the $files metadata table (use double-quotes in Trino)
SELECT
  COUNT(*) AS file_count,
  SUM(file_size_in_bytes) AS total_bytes,
  ROUND(SUM(file_size_in_bytes) / 1024.0 / 1024.0 / 1024.0, 2) AS total_gb,
  SUM(record_count) AS total_rows
FROM iceberg.analytics."events$files";
```

### Check snapshot history
```sql
SELECT
  snapshot_id,
  committed_at,
  operation
FROM iceberg.analytics."events$snapshots"
ORDER BY committed_at DESC
LIMIT 20;
```

If you have thousands of snapshots with `committed_at` older than 30 days, those are the ones `expire_snapshots` will remove.

---

## How to Schedule Maintenance So Storage Doesn't Keep Growing

Set up a **nightly + weekly job schedule** via Airflow, Kubernetes CronJobs, or whatever scheduler you already use:

**Nightly (4 AM, after your ingestion window closes):**
```sql
ALTER TABLE iceberg.analytics.events EXECUTE optimize(file_size_threshold => '128MB');
```

**Weekly (Sunday 3 AM when ingestion is paused):**
```sql
-- Step 1: Expire old snapshots (runs first)
ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '30d');

-- Step 2: Remove orphan files (runs after expire_snapshots)
ALTER TABLE iceberg.analytics.events EXECUTE remove_orphan_files(retention_threshold => '7d');
```

**Why this order matters:** if you run `remove_orphan_files` before `expire_snapshots`, there's a race condition with in-flight writes — a Spark job uploading a file but not yet committed could look like an orphan and get deleted prematurely. Always expire first, then remove orphans.

**Don't schedule compaction during ingestion.** If compaction and ingestion both try to commit changes to the same partition simultaneously, one fails with a commit retry. Ingest at 2 AM, compact at 4 AM, and do the weekly metadata maintenance in a separate window when ingestion is paused.

For each table in your catalog, run the procedures once per table — they don't take wildcards. With 10 tables you call the procedures 10 times per maintenance job.

---

## Bottom Line

Your storage is growing because maintenance was never set up. Scheduling those three steps (compaction → expire snapshots → remove orphans) on a nightly and weekly cadence will stop the growth and reclaim the excess MinIO space. Start with the Trino forms (`ALTER TABLE ... EXECUTE`) if you're already using Trino for queries — no need to set up Spark jobs unless you need sub-7-day retention or more tuning options.
