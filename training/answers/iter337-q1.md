# Answer to Q1: Orphan File Removal vs expire_snapshots (Iter 337)

You actually need both operations, and **they do NOT do the same thing**. `expire_snapshots` cleans up metadata; `remove_orphan_files` cleans up orphaned Parquet files on disk.

## What snapshot expiration leaves behind

When you run `expire_snapshots`, you're removing old **snapshot metadata** — the historical records that say "at this point in time, the table consisted of these data files." After expiration, those old snapshots disappear from Iceberg's snapshot list.

But the **Parquet data files** those old snapshots pointed to are still sitting on MinIO. `expire_snapshots` only removes the metadata references. The actual files stay put until you explicitly tell Iceberg to delete them.

If snapshot A (old) and snapshot B (current) both reference the same Parquet file, `expire_snapshots` removes snapshot A but the file stays because snapshot B still needs it. Only when no *live* snapshot references a file does it become eligible for deletion.

## What orphan files are

Parquet files sitting on MinIO that **no snapshot references at all**. They typically appear when:
- A Spark or Trino write job crashes mid-upload — the file gets uploaded to MinIO but the commit fails, so it's never added to any snapshot's manifest.
- A compaction job dies partway through and leaves behind temporary files it never cleaned up.

`remove_orphan_files` scans MinIO and deletes anything that isn't referenced by any live snapshot.

## The right scheduling order (this matters for safety)

Run them in this order:

```
1. expire_snapshots (weekly)
2. remove_orphan_files (weekly, immediately after)
```

Why this order? After `expire_snapshots` removes old snapshots, the files they referenced now become eligible for cleanup by `remove_orphan_files`. Running `expire_snapshots` first establishes a clean boundary: any file older than your `older_than` threshold that still isn't referenced really is dead (not just mid-commit).

The `remove_orphan_files` default `older_than` is **3 days** — it only deletes files that have been unreferenced for 3+ days. That waiting period protects in-flight writes (a Spark job uploading a large file right now looks orphaned, but the 3-day grace period keeps it safe).

## Concrete scheduling example

```sql
-- Weekly (Sunday 3 AM when ingestion is paused)
ALTER TABLE iceberg.analytics.events 
EXECUTE expire_snapshots(retention_threshold => '30d');

-- Immediately after (same maintenance window)
ALTER TABLE iceberg.analytics.events 
EXECUTE remove_orphan_files(retention_threshold => '7d');
```

Note: On Trino 467, the minimum retention threshold is `7d` for both operations (Trino enforces a 7-day floor that Spark doesn't).

**Bottom line:** `expire_snapshots` alone won't recover storage. You need the full two-step: expire old snapshots, then sweep the files they freed up.

**Resources cited:** `/Users/hclin/github/recknihao/resources/17-iceberg-table-maintenance.md`
