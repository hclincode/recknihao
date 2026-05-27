# Iter 156 Q2 — Iceberg Time-Travel After Accidental DELETE

## Answer

## Yes, you can query the old data using Iceberg's snapshot history.

### What actually happened to your data

When the DELETE ran, Iceberg didn't immediately erase the rows:

1. In Iceberg 1.5.2 (which uses copy-on-write by default), the DELETE created **new Parquet files** without the deleted rows and pointed to them in a **new snapshot**.
2. The **previous snapshot** — the one that existed before the DELETE — still exists in Iceberg's metadata and **still references the original files** containing those 6 months of data.
3. The old data files are still sitting in MinIO; they're just no longer referenced by the current snapshot.

**The key point:** you have a recoverable backup built in, as long as the previous snapshot hasn't been expired by a maintenance job.

### How to query the old data

**Step 1: Find the snapshot ID from before the DELETE**

```sql
SELECT snapshot_id, committed_at, operation, summary
FROM iceberg.analytics."events$snapshots"
WHERE committed_at < TIMESTAMP '2026-05-20 00:00:00 UTC'  -- adjust to before the DELETE happened
ORDER BY committed_at DESC
LIMIT 5;
```

Adjust the timestamp to just before the accidental DELETE occurred. Look for the latest snapshot **before** the DELETE.

**Step 2: Query using the snapshot ID**

```sql
SELECT *
FROM iceberg.analytics.events
FOR VERSION AS OF <snapshot_id>
WHERE tenant_id = 42;
```

Replace `<snapshot_id>` with the actual ID from Step 1. This returns the table **as it existed** at that snapshot, including all the rows that were deleted.

You can use this to:
- Verify the data is still there
- Export to a recovery table: `CREATE TABLE recovered_events AS SELECT * FROM iceberg.analytics.events FOR VERSION AS OF <snapshot_id> WHERE tenant_id = 42`
- Compare record counts before and after the DELETE to confirm the scope of damage

### How far back can you go?

**By default: 7 days.** Iceberg keeps snapshots for a minimum of 7 days before expiry maintenance can clean them up. After that, snapshots are expired and their data files become eligible for cleanup.

Check your table's retention settings:

```sql
SELECT * FROM iceberg.analytics."events$properties"
WHERE key LIKE 'history.expire%';
```

Look for:
- `history.expire.max-snapshot-age-ms` — how old snapshots can be before expiry
- `history.expire.min-snapshots-to-keep` — minimum snapshots to always retain

If these are set to longer retention (e.g., 30 days), you have 30 days to recover.

### The critical window

**If `expire_snapshots` has already run since the DELETE, the old snapshot may be gone.** On this stack, that's typically a weekly job. If the DELETE happened Tuesday and maintenance ran Wednesday night, the snapshot is gone.

Check the current snapshots now:

```sql
SELECT snapshot_id, committed_at, operation
FROM iceberg.analytics."events$snapshots"
ORDER BY committed_at DESC
LIMIT 20;
```

If you don't see a snapshot from right before the DELETE time, it's been expired and the data is unrecoverable from Iceberg.

### Immediate recovery action

If the snapshot still exists, use Iceberg's rollback procedure. This moves the table pointer back without touching any files:

```sql
CALL iceberg.system.rollback_to_snapshot('analytics', 'events', <snapshot_id>);
```

This makes the old snapshot the current one again. All queries immediately see the pre-DELETE data. You can then decide whether to keep it rolled back or selectively re-insert only the rows that should have been retained.

**Do this immediately** — every maintenance job that runs (`expire_snapshots`) reduces your recovery window.

### Does it keep every version forever?

No. Iceberg retains snapshots for a configurable period (default 7 days, configurable per table), and only the minimum required by `min-snapshots-to-keep`. Once `expire_snapshots` runs and removes a snapshot, the old files become orphaned and `remove_orphan_files` can delete them from MinIO. After that, the data is gone permanently from the lakehouse.
