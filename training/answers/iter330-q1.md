# Answer to Q1: Iceberg $snapshots Diagnostics — What They Are and Which to Expire (Iter 330)

## What a snapshot is and why you need to manage them

A **snapshot** is a point-in-time record of your entire Iceberg table — think of it like a photograph of the table's state at a moment in time. Every single write operation (INSERT, UPDATE, DELETE, MERGE) creates a brand new snapshot. Because Iceberg never modifies files in place (it uses immutable Parquet files), each operation just creates new files and a new snapshot pointing to them. Without maintenance, those old snapshots stick around forever, and so do all the data files they reference — hence the storage bloat.

Here's a concrete example: imagine your SaaS tracks user events. Day 1, you INSERT 1 million event rows and create Snapshot #1. Day 2, you INSERT another million and create Snapshot #2. Day 3, compaction merges the old small files into bigger ones and creates Snapshot #3. But Snapshot #1 and #2 still exist in the table's metadata, and they still hold references to the old small files on your storage system. MinIO can't delete those old files because Iceberg says "Snapshot #1 still needs those files." That's why you end up with extra storage — the files pile up.

## Querying the `$snapshots` metadata table

This is exactly what `$snapshots` shows you. It's a special Iceberg metadata table that lists every snapshot your table ever created:

```sql
SELECT snapshot_id, committed_at, operation, summary
FROM iceberg.analytics."events$snapshots"
ORDER BY committed_at DESC
LIMIT 20;
```

(The double quotes around `"events$snapshots"` are required — the `$` character requires quoting in Trino.)

**What each column means:**
- `snapshot_id` — a unique identifier for that snapshot. This is what you use if you need to time-travel to a specific moment or roll back.
- `committed_at` — the timestamp when that snapshot was created.
- `operation` — what caused the snapshot: `APPEND` (INSERT), `OVERWRITE` (full rewrite), `DELETE`, `REPLACE_PARTITIONS`, etc.
- `summary` — metadata about what the operation did (row counts added/deleted, partition info, etc.).

## Deciding which snapshots are safe to delete

**Safe to expire:**
- Snapshots older than your retention window (e.g., older than 30 days). If you don't need to time-travel back further than 30 days for audits or rollbacks, you can expire anything older than that.

**Dangerous to expire (keep these):**
- Snapshots that active queries might still be reading from (time-travel queries via `FOR VERSION AS OF`).
- Snapshots tagged for long-term retention (e.g., month-end billing snapshots needed for audit purposes).
- The most recent snapshots — always keep the last N snapshots as a safety net.

## How `expire_snapshots` works

When you run `expire_snapshots`:
1. Iceberg marks snapshots older than your threshold as "expired."
2. Data files that **only** expired snapshots referenced become orphans — no longer needed.
3. Iceberg issues deletion commands to remove those orphaned files from MinIO.

**Critical sequence — always run in this order:**
1. **Compaction first** (`rewrite_data_files`) — merges small files, creating a new snapshot
2. **Then expire snapshots** (`expire_snapshots`) — old small files now only referenced by expired snapshots become eligible
3. **Then remove orphans** (`remove_orphan_files`) — sweeps up files from failed writes
4. **Finally rewrite manifests** (`rewrite_manifests`) — speeds up query planning

```sql
-- See what snapshots you have
SELECT snapshot_id, committed_at, operation
FROM iceberg.analytics."events$snapshots"
ORDER BY committed_at DESC
LIMIT 10;

-- Expire snapshots older than 30 days
-- (Trino 467 requires at least 7 days minimum)
ALTER TABLE iceberg.analytics.events 
EXECUTE expire_snapshots(retention_threshold => '30d');
```

## Setting table-level guardrails

Set table properties so every expire_snapshots run is protected:

```sql
ALTER TABLE iceberg.analytics.events
SET TBLPROPERTIES (
    'history.expire.min-snapshots-to-keep' = '5',
    'history.expire.max-snapshot-age-ms'   = '2592000000'  -- 30 days
);
```

These guardrails ensure you always keep at least 5 recent snapshots AND anything from the last 30 days, whichever is more conservative.

**Resources cited:** `/Users/hclin/github/recknihao/resources/17-iceberg-table-maintenance.md`
