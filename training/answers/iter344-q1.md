# Answer to Q1: Why Iceberg Maintenance Order Matters (Iter 344)

The order you copied is exactly right. Here's why flipping it causes problems — two distinct issues depending on which steps you swap.

## The correct order (and why)

1. **Compaction** (`rewrite_data_files`) — merges small files into large ones, creates a new snapshot referencing the big files
2. **Expire snapshots** (`expire_snapshots`) — removes old snapshots and physically deletes their unreferenced data files
3. **Remove orphan files** (`remove_orphan_files`) — sweeps for files that were never in any snapshot
4. **Rewrite manifests** (`rewrite_manifests`) — cleans up the snapshot metadata index

## Why compaction must come BEFORE expire_snapshots

Compaction writes new big files and creates a new snapshot referencing them. That new snapshot must exist before `expire_snapshots` runs.

If you flip it — expire first, then compact — `expire_snapshots` runs without knowing about the compacted files that are about to be created. It removes old snapshots based on what currently exists. Then compaction tries to write new files and create a snapshot, but the references it's building on may have been partially deleted. The freshly-compacted files may not be protected by any surviving snapshot at the moment expiry ran, leaving them exposed.

**The rule**: create the new snapshot first, so expiry sees the new files as protected before it removes anything old.

## Why expire_snapshots must come BEFORE remove_orphan_files

Two reasons:

**Reason 1: Exposing more files to orphan cleanup**

Old snapshots act like "leases" on the files they reference. As long as an old snapshot exists, `remove_orphan_files` sees those files as in-use and leaves them alone — even if no current query needs them.

When you run `expire_snapshots` first, those old snapshots are dropped. Their files are no longer referenced by anything. Now when `remove_orphan_files` runs, it correctly identifies those files as orphans and deletes them.

If you flip it — orphan cleanup first, then expire — the old snapshot is still there during the orphan scan. The files it references look "in-use" to `remove_orphan_files`, so they survive. Then `expire_snapshots` drops the old snapshot, making those files truly orphaned. But `remove_orphan_files` already ran, so they sit undeleted until next week. **Result: an extra week of unnecessary storage cost.**

**Reason 2: Protecting against in-flight writes**

When a Spark job writes new data, it uploads files to MinIO before committing them into a snapshot. For a brief window, those files exist on disk with no snapshot pointing at them — they look like orphans. If `remove_orphan_files` runs during that window with an aggressive `older_than` threshold, it deletes those in-flight files. When the write commits and references the (now-deleted) files, the table breaks — queries fail with "file not found."

Running `expire_snapshots` first establishes a clean cutoff. The 7-day default on `remove_orphan_files` then ensures any file that could plausibly still be in-flight (any file younger than 7 days) is left untouched.

## Quick mnemonic

- **Compact before expire**: new snapshot must exist before old ones are removed
- **Expire before orphan**: old snapshots must be dropped to expose their files; drops also protect in-flight writes by resetting the "clock"
- **Orphan before manifests**: clean the data layer before rebuilding the metadata index

## What specifically breaks if you flip

| Swap | What breaks |
|---|---|
| Expire first, then compact | Compaction's new files may not be protected during expiry; old snapshots removed before new replacement exists |
| Orphan cleanup first, then expire | Files protected by old snapshots survive orphan scan; linger an extra week after expiry drops those snapshots |
| Either reversal | Risk of deleting in-flight write files, breaking table integrity |

Your copied order is safe. Document the rationale in your runbook and don't change it without a specific reason.

**Resources cited:** `/Users/hclin/github/recknihao/resources/17-iceberg-table-maintenance.md`
