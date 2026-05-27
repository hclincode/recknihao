# Answer to Q2: remove_orphan_files Error on 6-Hour retention_threshold (Iter 340)

Yes, the error you got is expected and intentional — you hit Trino's **7-day minimum retention floor**.

## What happened

When you passed `retention_threshold => '6h'` (or `'6d'` if you meant 6 days), Trino rejected the call immediately with an error rather than running conservatively. The error looks something like:

```
Retention specified (6.00h) is shorter than the minimum retention configured in the system (7.00d)
```

The call never ran. No files were deleted, and no files were silently skipped — the entire procedure failed at the front door.

This is controlled by a catalog property: `iceberg.remove-orphan-files.min-retention` (default: `7d`). Any `retention_threshold` you pass that is shorter than this floor causes Trino to throw an explicit error and abort.

## Why Trino errors instead of just being conservative

You might expect it to say "fine, I'll just apply the floor myself and skip the recent files." The reason it doesn't is that **the error makes the safety violation visible**. If Trino silently applied the floor, you might think cleanup ran on the recent orphans when it actually didn't — a hidden gap. Erroring immediately tells you exactly what happened and why.

## Why the floor exists at all

The 7-day floor protects against a specific corruption scenario:

1. A Spark job starts writing a large Parquet file to MinIO at 2 AM but crashes before committing the Iceberg snapshot. The file sits unreferenced.
2. A separate write job is still in flight, uploading files that also look unreferenced because they haven't been committed yet.
3. You run `remove_orphan_files` with `retention_threshold => '6h'` at 8 AM. The cleanup sees those in-flight files, identifies them as orphans, and deletes them.
4. That still-running write job now tries to commit its snapshot referencing the deleted files. The commit succeeds (metadata points at the files), but the files are gone from MinIO.
5. Every query on that snapshot now fails with "file not found." Table corruption.

The 7-day floor exists because a file that has been unreferenced for 7 days is almost certainly not part of any in-flight write — any reasonable Spark job (even with retries) has either committed or permanently failed by then.

## What to do about your 2 AM orphans

**Option 1 — Wait (safest, recommended)**

Run `remove_orphan_files` in your weekly maintenance window. The orphans will be cleaned up automatically once they pass 7 days old. They're costing you MinIO storage but they're not affecting query correctness.

```sql
-- Trino — safe and correct, run weekly
ALTER TABLE iceberg.analytics.events
EXECUTE remove_orphan_files(retention_threshold => '7d');
```

**Option 2 — Use Spark with ingestion paused**

Spark does not enforce the 7-day floor. If you genuinely need to clean those files now:

1. Pause all ingestion to the table
2. Wait a few minutes to ensure no in-flight writes are still committing
3. Run from Spark (not Trino):

```sql
-- Spark SQL — first do a dry run to verify what would be deleted
CALL iceberg.system.remove_orphan_files(
  table      => 'analytics.events',
  older_than => current_timestamp - interval '6' hour,
  dry_run    => true
);
```

4. If the dry run output looks right, run again without `dry_run => true`
5. Resume ingestion

**Do not skip pausing ingestion.** The corruption risk is real.

## Key takeaway

Trino's error on `retention_threshold => '6h'` is a safety feature, not a bug. The explicit error message tells you exactly what's wrong and why. For your weekly maintenance schedule, always use `retention_threshold => '7d'` in Trino — it matches the floor, never errors, and is safe to run even while ingestion is active.

**Resources cited:** `/Users/hclin/github/recknihao/resources/17-iceberg-table-maintenance.md`
