# Iter 153 Q2 — Iceberg DELETE Storage Growth: Why MinIO Keeps Growing

## Answer

Your observation is correct, and the explanation is in how Iceberg's immutable-file architecture handles deletes. **When you delete rows, Iceberg does not shrink existing Parquet files — it creates new files and keeps the old ones alive until you run explicit maintenance steps.** Without those steps, MinIO storage grows with every delete, even when you're removing more rows than you're inserting.

### How Iceberg deletes actually work (Copy-on-Write mode)

Your production stack runs Iceberg 1.5.2 with Copy-on-Write (CoW) as the default delete mode. When your cleanup job runs:

```sql
DELETE FROM iceberg.analytics.events WHERE tenant_id IN ('churn-tenant-1', 'test-tenant-2');
```

Iceberg does this:
1. **Reads every Parquet file that contains at least one matching row**
2. **Rewrites those files**, dropping the matching rows, producing new Parquet files with only the survivors
3. **Creates a new snapshot** pointing to the new files
4. **Leaves the old files on MinIO** — they are no longer referenced by the current snapshot, but they are still referenced by the previous snapshot

The old files are not deleted. They are kept alive by historical snapshots for time-travel and rollback capability.

**After your DELETE runs, MinIO has:**
- The original Parquet files (still on disk, protected by the prior snapshot)
- The new, smaller Parquet files (referenced by the current snapshot)
- New snapshot metadata

Storage grew, not shrank. If you delete 60% of rows in a file, Iceberg rewrites 100% of the file to a new location — you temporarily have both versions on disk.

### The three steps that actually free space

Your DELETE is only Step 1 of a 4-step process. Steps 2–4 are what actually free MinIO storage:

```sql
-- Step 1: Your nightly DELETE (already running) ✓
DELETE FROM iceberg.analytics.events WHERE ...;

-- Step 2: Compact small files after the DELETE (run after Step 1 completes)
-- Spark form (recommended):
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.events',
  options => map('target-file-size-bytes', '268435456', 'min-input-files', '5')
);
-- Or Trino form:
ALTER TABLE iceberg.analytics.events EXECUTE optimize(file_size_threshold => '128MB');

-- Step 3: Expire old snapshots — THIS IS THE CRITICAL STEP
-- This removes the old snapshot that was protecting the pre-delete files.
-- Until this runs, the old files cannot be deleted.
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.events',
  older_than  => current_timestamp - interval '30' day,
  retain_last => 10
);

-- Step 4: Remove orphaned files — actually deletes from MinIO
-- Only files that are no longer referenced by any snapshot are deleted here.
CALL iceberg.system.remove_orphan_files(
  table      => 'analytics.events',
  older_than => current_timestamp - interval '3' day
);
```

**Storage only drops after Steps 3 AND 4 complete — in that order.** Step 3 must run before Step 4 because `expire_snapshots` is what makes the old files "orphaned" (no longer referenced by any snapshot). If you run Step 4 first, it won't delete anything because the old files are still referenced.

### Why snapshot expiry is the key

After your DELETE:
- The new snapshot sees the rows as deleted ✓
- The old snapshot (from before the DELETE) still references the original Parquet files

Until `expire_snapshots` removes that old snapshot, those original files are protected. `remove_orphan_files` only deletes files that no snapshot references. Without `expire_snapshots`, you can delete 10 million rows and MinIO grows every week.

### Check how many snapshots are accumulating

```sql
SELECT COUNT(*) AS snapshot_count
FROM iceberg.analytics.events$snapshots;

SELECT snapshot_id, committed_at, operation
FROM iceberg.analytics.events$snapshots
ORDER BY committed_at DESC
LIMIT 20;
```

If the snapshot count grows week over week with no decrease, you are not running `expire_snapshots`. Look for a `replace` operation (from compaction) or `overwrite` (from DELETE) in the operation column.

### Recommended schedule going forward

```
Nightly (after your DELETE job):
  1. DELETE (your existing job) ✓
  2. rewrite_data_files (compaction)

Weekly (Sunday low-traffic window):
  3. expire_snapshots — with 30-day retention
  4. remove_orphan_files
```

This schedule frees up storage weekly and keeps snapshot count under control. With 30-day retention, you also keep a 30-day rollback window for incident recovery.

### MoR mode as an alternative (for high-frequency deletes)

If your cleanup job deletes from many files each night, CoW mode is expensive — it rewrites every touched file on each DELETE. An alternative is Merge-on-Read (MoR), where Iceberg writes lightweight delete marker files instead of rewriting data files immediately. MoR deletes are cheaper upfront but require periodic compaction to actually remove the deleted rows from storage. For nightly batch deletes, CoW is usually the right choice — MoR is more beneficial for high-frequency small deletes throughout the day.

### Summary

| Why storage grows | The fix |
|---|---|
| DELETE rewrites files but keeps originals | Run `expire_snapshots` to release old snapshots |
| Old snapshots protect original files | Run `remove_orphan_files` after expire_snapshots to delete from MinIO |
| No maintenance schedule | Add weekly expire + remove_orphan to your Airflow/CronJob schedule |

The delete rows are logically gone immediately. The bytes are freed from MinIO only after `expire_snapshots` + `remove_orphan_files` run.
