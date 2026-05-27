# Answer to Q1: Crashed Write Files vs expire_snapshots (Iter 338)

Your teammate is **absolutely right**. These are two completely different categories of garbage, and snapshot expiration will *not* clean up the files from your crashed write. You need both procedures running.

## What `expire_snapshots` handles

When you insert or update data in Iceberg, the system creates a new snapshot pointing at the new data files and leaves the old snapshot behind. The old snapshot still has references to the old data files, so those files cannot be deleted — Iceberg never deletes anything a live snapshot still points to.

**`expire_snapshots` removes old snapshots from the table's history AND physically deletes any data files that snapshot exclusively owned.** Those files are no longer referenced by any live snapshot, so they're safe to delete.

Think of it as: "This snapshot is old, nobody time-travels to it anymore, so we can forget about it — and anything only it was holding onto can be discarded."

## What `remove_orphan_files` handles

Your crashed Spark job is the key scenario here. The job uploaded a Parquet file to MinIO, then crashed *before* writing the Iceberg commit that would have created a snapshot pointing to that file. The file sits in MinIO completely unreferenced by any snapshot.

**`remove_orphan_files` does a full directory scan of MinIO** looking for files that no current snapshot points to. It finds these orphaned files and deletes them.

Think of it as: "Are there files sitting in MinIO that nobody is tracking in any snapshot? Scan for those and clean them up."

## The critical difference

| | expire_snapshots | remove_orphan_files |
|---|---|---|
| What it handles | Files that WERE in snapshots, now aged out | Files NEVER in any snapshot (crashed writes, temp files) |
| How it finds them | Follows snapshot manifest references | Full directory scan of MinIO |
| Your nightly cron handles crash leftovers? | **No** | **Yes** |

`expire_snapshots` only knows about files referenced by snapshots — it cannot see your crashed write's orphan because that file never made it into a snapshot. Your nightly `expire_snapshots` would run and find nothing to do about those partial files.

## What your schedule should look like

Run both, in this order:

1. **Compaction** (`rewrite_data_files`) — nightly
2. **Snapshot expiration** (`expire_snapshots`) — weekly, drops old snapshots + physically deletes their exclusively-owned files
3. **Orphan cleanup** (`remove_orphan_files`) — weekly, immediately after expiration
4. **Manifest rewrite** (`rewrite_manifests`) — weekly

Running `remove_orphan_files` before `expire_snapshots` creates a race condition risk — a new job's file might not yet be committed when orphan cleanup runs. Running expiry first narrows that window.

The files from your crash are exactly what `remove_orphan_files` is designed for — it will find them, confirm nothing references them, and delete them. Your nightly `expire_snapshots` alone would never touch them because they never made it into a snapshot.

**Resources cited:** `/Users/hclin/github/recknihao/resources/17-iceberg-table-maintenance.md`
