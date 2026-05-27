# Answer to Q2: Time-Travel Snapshot Storage Cost (Iter 321)

You've identified the core problem correctly — Iceberg's time-travel feature keeps old snapshots around, and those snapshots hold data files hostage. Let me break down exactly what's happening, how to estimate the cost, and what your tradeoff options are.

## What Time-Travel Is Actually Storing

Every write to your Iceberg table creates a **snapshot** — a metadata record pointing to which Parquet data files exist at that moment. When you keep old snapshots:

1. **The data files those snapshots reference stay on MinIO** — even if they've been "replaced" by newer files, Iceberg won't delete them because an old snapshot still points to them.
2. **Compaction makes this worse** — compaction writes new (bigger) Parquet files but keeps the old (small) files around. Without expiring snapshots, you now have both the new files AND the old ones on disk.

For a table updated heavily every day:

> **Without snapshot expiry, a 100 GB table can balloon to 300+ GB in a year just from snapshot accumulation.** Every compaction adds new files while keeping the old ones around (because snapshots still reference them). This is the most common storage cost surprise on self-hosted Iceberg setups.

## How to Estimate Time-Travel Storage Cost

**Step 1: Measure your current snapshot count.**

```sql
SELECT COUNT(*) AS snapshot_count
FROM iceberg.analytics."<your_table>$snapshots";
```

**Step 2: Count data files across all snapshots.**

```sql
SELECT COUNT(*) AS total_files,
       AVG(file_size_in_bytes) AS avg_file_size_bytes
FROM iceberg.analytics."<your_table>$files";
```

**Step 3: Estimate overhead.** If you have 5,000 snapshots on a table that should have 1,000 data files, you're storing ~5× more than needed (~80% overhead from snapshot accumulation).

**Rough formula:**

```
Storage cost = base_data_size × (1 + (retention_days / 100))
```

For a 500 GB table:
- 7 days: ~510 GB (+2%)
- 30 days: ~650 GB (+30%)
- 90 days: ~950 GB (+90%)
- No expiry (current situation): ~1.5–2 TB after a few months

## The Root Cause: Missing `expire_snapshots`

**Iceberg's default behavior is to keep every snapshot forever.** The 7-day minimum retention floor (Trino's `iceberg.expire-snapshots.min-retention`) means you can't delete anything younger than 7 days, but there's no upper bound by default.

## The Fix: Schedule `expire_snapshots` + `remove_orphan_files`

Both steps are required — one without the other won't reclaim disk space.

**Step 1: Expire old snapshots (weekly)**

```sql
-- Spark SQL (recommended for large tables)
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.<your_table>',
  older_than  => current_timestamp - interval '30' day,
  retain_last => 10
);
```

Or from Trino:

```sql
ALTER TABLE iceberg.analytics.<your_table>
EXECUTE expire_snapshots(retention_threshold => '30d');
```

**Step 2: Remove orphan files (after expire_snapshots)**

```sql
-- Spark SQL (run after expire_snapshots)
CALL iceberg.system.remove_orphan_files(
  table      => 'analytics.<your_table>',
  older_than => current_timestamp - interval '3' day,
  dry_run    => false
);
```

Always run `dry_run => true` first to verify which files will be deleted.

## Why Storage Grows After Compaction (and Why Both Steps Matter)

This confuses many operators:

1. **Compaction writes new files** → MinIO usage **grows** temporarily
2. **Snapshots still point to old files** → they can't be deleted yet
3. **`expire_snapshots` removes old snapshots** → old files now eligible for deletion
4. **`remove_orphan_files` deletes the old files** → MinIO usage **finally drops**

You need all three steps (compaction → expire snapshots → remove orphans) or storage never actually reclaims space.

## Recommended Schedule

- **Nightly compaction:** after your ingestion window closes
- **Weekly snapshot expiry + orphan cleanup:** Sunday off-hours

```sql
-- WEEKLY maintenance job
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.events',
  older_than  => current_timestamp - interval '30' day,
  retain_last => 10
);

CALL iceberg.system.remove_orphan_files(
  table      => 'analytics.events',
  older_than => current_timestamp - interval '3' day
);
```

## The Retention Tradeoff

| Retention window | Use case | Storage overhead |
|---|---|---|
| 7 days (minimum) | Recovery from bad ingestion jobs | ~2% |
| 30 days (common) | Data bug recovery, billing disputes | ~30% |
| 90 days (compliance) | SOX/audit windows | ~90% |
| No expiry (current) | Unlimited history | 200–300% within a year |

**On bare-metal MinIO:** there's no per-GB cost beyond hardware, so the question is disk capacity. If you're at 70%+ MinIO utilization, drop to 7 days. If you have headroom, 30 days is a comfortable default.

## Verify Expiry Is Running

If you've never scheduled this, check:

```sql
SELECT COUNT(*) FROM iceberg.analytics."<table>$snapshots";
```

If this number is in the thousands or grows daily, expiry is NOT running. Schedule it immediately — you'll see MinIO storage drop noticeably within 24 hours after the first run.
