# Answer to Q1: Storage Costs Jumped 40% and Historical Data Doesn't Match

## What's happening

Your symptoms point to two separate problems:
1. **Storage jumped because Iceberg snapshots are accumulating** — Iceberg never modifies files in place. Without snapshot expiry, old versions stack up forever.
2. **Historical queries return different results** because something changed the data after the original report (a DELETE, UPDATE, or bad ingestion run).

Both are fixable with a safe, ordered cleanup process.

## The critical order (do not skip steps or reverse them)

Iceberg maintenance has four procedures. Run them in this order:

1. **Compaction** (`rewrite_data_files`) — merge small files into bigger ones
2. **Snapshot expiry** (`expire_snapshots`) — mark old versions as expired
3. **Orphan cleanup** (`remove_orphan_files`) — physically delete unreferenced files from MinIO
4. **Manifest rewrite** (`rewrite_manifests`) — compress metadata

**Why order matters:** If you run orphan cleanup before snapshot expiry, you can hit a race condition. A Spark write job uploading a new Parquet file mid-commit can have that file deleted by an aggressive orphan cleanup if `older_than` is too short. The commit then references a file that no longer exists — the table is corrupted. Expiring snapshots first ensures everything in-flight from the last 3+ days is either committed or already garbage.

## The cleanup runbook (copy-paste for your stack)

Run these in **Spark** (not Trino — Spark's Iceberg procedures accept flexible retention windows; Trino's ALTER TABLE EXECUTE optimize is for bin-pack compaction only, not the full maintenance suite):

```sql
-- STEP 1: Compact data files (merge small files into 256 MB chunks)
-- Storage temporarily goes UP here (new big files + old small files both exist)
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.events',
  options => map(
    'target-file-size-bytes', '268435456',  -- 256 MB
    'min-input-files',        '5'
  )
);

-- STEP 2: Expire old snapshots (removes references to old files)
-- 30-day window gives a comfortable rollback buffer
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.events',
  older_than  => current_timestamp - interval '30' day,
  retain_last => 10
);

-- STEP 3a: Preview orphan files first — ALWAYS do a dry run before deleting
CALL iceberg.system.remove_orphan_files(
  table   => 'analytics.events',
  dry_run => true
);

-- STEP 3b: Delete orphan files (the 3-day default protects in-flight writes)
CALL iceberg.system.remove_orphan_files(
  table      => 'analytics.events',
  older_than => current_timestamp - interval '3' day
);

-- STEP 4: Rewrite manifests (speeds up future query planning)
CALL iceberg.system.rewrite_manifests(
  table => 'analytics.events'
);
```

## Why storage went up 40% when data grew 15%

Each compaction run writes new large Parquet files alongside the old small ones. The old small files stay on disk until snapshot expiry removes their references, and then orphan cleanup physically deletes them from MinIO. After step 1 alone, storage looks *worse* — it only drops visibly after steps 2 and 3 complete. This is expected and safe.

## Investigating the historical data mismatch

The fact that a two-month-old report now returns different numbers usually means:
1. Someone ran a DELETE or UPDATE after the original report, OR
2. A bad ingestion job temporarily inserted duplicates or wrong data, OR
3. Schema changed (column added/dropped/renamed)

**Investigate without guessing — query the old snapshot directly:**

```sql
-- Trino: find snapshots around the time of the old report
SELECT snapshot_id, committed_at, operation
FROM iceberg.analytics."events$snapshots"
WHERE committed_at BETWEEN TIMESTAMP '2026-03-25 00:00:00'
                      AND TIMESTAMP '2026-03-26 00:00:00'
ORDER BY committed_at DESC;
```

Then re-run the old report against that exact snapshot:

```sql
-- Compare against what the data looked like at the time
SELECT ... FROM iceberg.analytics.events
FOR VERSION AS OF <snapshot_id>
-- [rest of your original report query]
```

If numbers match → something changed the data after that date. If they don't → bad data was already there (ingestion issue).

**Warning**: once you run `expire_snapshots` with a 30-day window, snapshots older than 30 days are gone and you can no longer do this time-travel. If you need to investigate a 2-month-old snapshot, do it **before** running the cleanup.

## Why this is safe to run with ingestion still active

- Compaction only rewrites files; it never deletes anything.
- Snapshot expiry only removes metadata references, not files still referenced by any snapshot.
- Orphan cleanup's 3-day `older_than` default means files younger than 3 days are never touched, protecting any in-flight write jobs running at the same time.

The one thing to avoid: don't lower `older_than` below 3 days for orphan cleanup while ingestion is running. The 3-day window is calibrated for exactly this use case.

## Schedule it permanently

Run nightly (after ingestion finishes, e.g., 4 AM):
- Compaction (`rewrite_data_files`)

Run weekly (Sunday 3 AM low-traffic window):
- Expire snapshots
- Remove orphan files
- Rewrite manifests

Wire this up in Airflow or a Kubernetes CronJob. Without this, the 40% storage creep will repeat every 8 months.
