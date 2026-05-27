# Answer to Q1: Iceberg Table Maintenance Without Spark

## You do NOT need Spark

Trino 467 has full native support for all routine Iceberg maintenance operations. You can run everything directly from Trino using `ALTER TABLE ... EXECUTE` syntax. Adding a Spark cluster just for maintenance is unnecessary.

## The Trino-native maintenance commands

```sql
-- STEP 1: Compact small files (nightly — run after ingestion finishes)
ALTER TABLE iceberg.analytics.events EXECUTE optimize(file_size_threshold => '256MB');

-- STEP 2: Expire old snapshots (weekly)
-- Trino enforces a 7-day minimum — '30d' gives a comfortable rollback window
ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '30d');

-- STEP 3: Remove orphan files (weekly, after step 2)
-- Same 7-day minimum floor — files younger than 7d are never touched
ALTER TABLE iceberg.analytics.events EXECUTE remove_orphan_files(retention_threshold => '7d');
```

These three steps handle why your S3 costs are climbing. Run them in this order — orphan files can only be safely deleted after snapshots are expired (otherwise you delete files that unreferenced-but-not-yet-expired snapshots still point to).

## Why costs keep climbing without maintenance

Every write to Iceberg creates new Parquet files and a new snapshot. The previous small files don't disappear — Iceberg keeps them to support time travel. Without maintenance:

1. Compaction writes new big files but doesn't delete old small ones (they're still referenced by old snapshots)
2. `expire_snapshots` removes the old snapshot references (old files become orphans)
3. `remove_orphan_files` physically deletes them from MinIO/S3

After step 1 alone, storage looks *worse*. Costs only drop visibly after all three steps complete.

## One caveat: no dry-run preview in Trino

Trino's `remove_orphan_files` does not support a `dry_run` parameter — the deletion is immediate and irreversible. If you want to preview what would be deleted before running it for the first time, you'd need to run the Spark form with `dry_run => true`:

```sql
-- Spark-only dry run (one-time preview before your first production run)
CALL iceberg.system.remove_orphan_files(
  table   => 'analytics.events',
  dry_run => true
);
```

Once you're comfortable that maintenance is working correctly, the Trino form handles all subsequent runs.

## The one thing Trino 467 cannot do: manifest rewrite

`rewrite_manifests` (metadata compression) is not available in Trino 467 — it was added as `EXECUTE optimize_manifests` in Trino 470 (Feb 2025). This is a nice-to-have for query planning speed, not a correctness requirement. Skip it for now; it doesn't affect storage costs. If you upgrade Trino past 470, you can add:

```sql
-- Trino 470+ only (not available on 467)
ALTER TABLE iceberg.analytics.events EXECUTE optimize_manifests;
```

## The 7-day minimum retention floor

Trino enforces a minimum of 7 days for both `expire_snapshots` and `remove_orphan_files`. Passing anything shorter (e.g., `'3d'`) raises an error. This floor protects in-flight writes running at the same time as maintenance. For standard operational use, 7 days is plenty — just use `'7d'` as your minimum or `'30d'` for snapshots.

The only case where you'd need sub-7-day purge is GDPR right-to-erasure (same-day deletion), which requires Spark. For normal cost control, Trino is fully sufficient.

## Recommended schedule (Trino only)

**Nightly** (after ingestion, e.g., 4 AM):
```sql
ALTER TABLE iceberg.analytics.events EXECUTE optimize(file_size_threshold => '256MB');
```

**Weekly** (Sunday 3 AM low-traffic window):
```sql
ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '30d');
ALTER TABLE iceberg.analytics.events EXECUTE remove_orphan_files(retention_threshold => '7d');
```

Wire these into Kubernetes CronJobs that run `trino --execute "..."` commands. No Spark cluster needed.

## Summary

You can run all meaningful Iceberg maintenance from Trino 467. The only Spark-only caveat is the dry-run preview (one-time) and manifest rewrite (skip until you upgrade). Your S3 cost growth will stabilize once you have nightly compaction + weekly snapshot expiry + weekly orphan cleanup running on a schedule.
