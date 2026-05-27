# Iter 149 Q1 — Iceberg Time Travel After Accidental DELETE

## Answer

Yes — Iceberg keeps history, and you can absolutely read the deleted data back. Here is how it works and what your options are.

### How Iceberg's history works

Iceberg is built on immutable files. When a DELETE runs, it does not erase anything — it creates a new snapshot (a point-in-time version of the table) that simply does not reference the deleted rows. The old snapshot that contains those rows is still in Iceberg's metadata. As long as that snapshot has not been expired, you can query the table as it existed at that moment. This is called **time travel**.

### Step 1: Find the pre-DELETE snapshot

Query the `$snapshots` metadata table to find the snapshot from before the DELETE:

```sql
SELECT snapshot_id, committed_at, operation, summary
FROM iceberg.analytics.events$snapshots
ORDER BY committed_at DESC
LIMIT 20;
```

Look for the last snapshot with `operation = 'append'` or `overwrite` before the delete timestamp. The snapshot immediately before the DELETE is what you want.

### Step 2: Verify the data is still there with time travel

Once you have the snapshot ID (e.g., `4823511203987654321`), confirm the deleted rows are accessible:

```sql
-- Query by snapshot ID
SELECT COUNT(*)
FROM iceberg.analytics.events FOR VERSION AS OF 4823511203987654321
WHERE event_date >= DATE '2026-05-24';
```

If you know the timestamp but not the snapshot ID, you can use:

```sql
-- Query by timestamp — resolves to the latest snapshot at or before this time
SELECT COUNT(*)
FROM iceberg.analytics.events FOR TIMESTAMP AS OF TIMESTAMP '2026-05-24 00:00:00 UTC';
```

### Step 3: Recover the data — three options

**Option A: Rollback (best if no correct writes landed after the DELETE)**

If the DELETE just happened and no valid data arrived after it, roll the table pointer back to the pre-DELETE snapshot. This is instant and atomic — it only moves a metadata pointer, no data files are touched:

```sql
-- Trino 467 form (positional args: schema, table, snapshot_id)
CALL iceberg.system.rollback_to_snapshot('analytics', 'events', 4823511203987654321);
```

All deleted rows reappear immediately. This is the cleanest fix if the DELETE is the last operation.

**Caveat**: If correct data arrived *after* the DELETE (e.g., new events from your ingestion pipeline), rolling back also undoes those correct writes. In that case, use Option B.

**Option B: Selective re-insert from the old snapshot**

If correct writes landed after the DELETE, query the old snapshot selectively and re-insert only the missing rows:

```sql
INSERT INTO iceberg.analytics.events
SELECT *
FROM iceberg.analytics.events FOR VERSION AS OF 4823511203987654321
WHERE event_date >= DATE '2026-05-24'
  AND event_date < DATE '2026-05-26';
```

If your table has a natural dedup key, an `event_id`-based MERGE INTO is safer than INSERT to avoid double-counting rows that were not deleted:

```sql
MERGE INTO iceberg.analytics.events AS target
USING (
  SELECT * FROM iceberg.analytics.events FOR VERSION AS OF 4823511203987654321
  WHERE event_date >= DATE '2026-05-24'
) AS recovered
ON target.event_id = recovered.event_id
WHEN NOT MATCHED THEN INSERT *;
```

**Option C: Check if the snapshot is still there first**

Before doing anything, verify the pre-DELETE snapshot still exists — if `expire_snapshots` already ran and removed it, the time travel path is gone:

```sql
SELECT COUNT(*)
FROM iceberg.analytics.events$snapshots
WHERE committed_at >= TIMESTAMP '2026-05-24 00:00:00 UTC'
  AND committed_at < TIMESTAMP '2026-05-26 00:00:00 UTC';
```

If this returns zero, those snapshots have already been expired and you cannot use time travel. If it returns a non-zero count, you are safe — the data is still accessible.

### Why the data is still there (for now)

Your DELETE ran as copy-on-write (CoW), the Iceberg 1.5.2 default. It rewrote the affected Parquet files without the deleted rows and created a new snapshot. The old snapshot that still contained those rows remains in the table metadata until `expire_snapshots` removes it. With the standard Trino 7-day minimum retention floor, yesterday's snapshot is definitely still there.

### Going forward: maintain a recovery window

Keep snapshot retention at **30 days** so you have a meaningful rollback window for future incidents. The standard maintenance schedule is:

- **Nightly**: `rewrite_data_files` (compaction)
- **Weekly**: `expire_snapshots` with 30-day retention → `remove_orphan_files` → `rewrite_manifests`

With 30-day retention you can roll back or time-travel up to a month back. The 7-day floor Trino enforces is the absolute minimum — 30 days is the practical recommendation for incident response.

### Summary

| Step | What to run |
|---|---|
| Find pre-DELETE snapshot | `SELECT snapshot_id, committed_at FROM ...events$snapshots ORDER BY committed_at DESC` |
| Verify data exists | `SELECT COUNT(*) FROM ... FOR VERSION AS OF <id>` |
| Rollback (no later writes) | `CALL iceberg.system.rollback_to_snapshot('analytics', 'events', <id>)` |
| Selective re-insert | `INSERT INTO ... SELECT * FROM ... FOR VERSION AS OF <id> WHERE ...` |

The data is not lost — it is just invisible under the current snapshot. Iceberg keeps the full history as long as the snapshot metadata exists.
