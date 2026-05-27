# Answer to Q2: remove_orphan_files Ran but Didn't Clean Up Recent Files (Iter 339)

Your `remove_orphan_files` didn't delete those files because of Trino's safety floor, not a bug.

When you ran `remove_orphan_files` from Trino this morning, the procedure looked at those orphan files and saw they were created last night — roughly 10–12 hours ago. The procedure then said "no, I'm not deleting those yet" and skipped them.

## Why: Trino's mandatory 7-day minimum retention floor

**Trino enforces a mandatory 7-day minimum retention threshold on `remove_orphan_files`.** This is controlled by the catalog property `iceberg.remove-orphan-files.min-retention` (default: 7 days). When you call the procedure, Trino will not delete any file younger than that floor, regardless of what you pass as an argument.

## Why a 7-day floor exists

The floor protects against a nasty race condition:

1. Your Spark job crashes mid-write at 1 AM, leaving a Parquet file uploaded to S3 but not yet referenced by any Iceberg snapshot.
2. You run `remove_orphan_files` at 2 AM with an aggressive `older_than` of a few hours.
3. The procedure sees the file (unreferenced), so it deletes it from S3.
4. But your Spark job is still in its retry logic, about to commit the snapshot that references that file.
5. The commit succeeds, but the file is gone. Now the table points at non-existent data, and every query fails with "file not found."

The 7-day floor prevents this. A file that's sat orphaned for 7 days almost certainly will never be committed — any reasonable Spark write (even with retries) has long since either succeeded or failed by then.

## What to do with your 10-12 hour old orphans

**Option 1 — Wait it out (safest).** Let the files sit for a few more days. Re-run `remove_orphan_files` from Trino next week and they'll be cleaned up. Temporary storage cost for a few extra MB for a week is negligible.

**Option 2 — Use Spark to bypass the floor.** Trino enforces the 7-day floor, but Spark does not. You can run the procedure from Spark with a shorter `older_than`:

```sql
-- Spark SQL (NOT Trino — Spark has no 7-day floor)
CALL iceberg.system.remove_orphan_files(
  table      => 'analytics.events',
  older_than => current_timestamp - interval '12' hour,
  dry_run    => true   -- preview first without deleting
);
```

First run with `dry_run => true` to see which files would be deleted. If you're certain your Spark job is not still retrying its commit, then run again without `dry_run => true` to actually delete. **Do not use a shorter `older_than` than the longest duration your Spark job could plausibly still be retrying.**

**Option 3 — Temporarily lower Trino's catalog floor.** Change `iceberg.remove-orphan-files.min-retention` in your Trino config, but this requires a coordinator restart. Most teams avoid this for a few extra MB of temporary storage.

## Key takeaway

The procedure worked correctly — it protected your table by refusing to delete files young enough that a write could still be referencing them. The "nothing happened" feeling is actually Iceberg protecting your data.

**Resources cited:** `/Users/hclin/github/recknihao/resources/17-iceberg-table-maintenance.md`
