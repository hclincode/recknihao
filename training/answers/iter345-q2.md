# Answer to Q2: Why rewrite_manifests Goes Last in Iceberg Maintenance (Iter 345)

## What are manifests?

A **manifest file** is an Iceberg metadata file — a table of contents listing which Parquet data files belong to a snapshot, plus per-column min/max statistics for each file. This is metadata, not data.

Your Iceberg table has three layers:
1. **Data layer** — the actual Parquet files in MinIO (your actual rows)
2. **Manifest layer** — small metadata files listing which data files exist and their statistics
3. **Snapshot layer** — a pointer saying "this set of manifests defines the current table state"

When Trino plans a query, it must read every manifest file before reading any data file. On an unmaintained table after months of streaming writes, you can have 50,000+ tiny manifest files — almost one created per write. Trino spends 30+ seconds just reading manifests before the query even starts executing.

`rewrite_manifests` consolidates those many small manifests into a few large ones, sorted by partition. Query planning time drops from 30+ seconds to under 1 second.

## Why it goes last: compaction, expire, and orphan cleanup all generate new manifests

Every data-layer maintenance operation produces new manifest files as a side effect:

- **Compaction** merges small Parquet files into large ones and creates a new snapshot — which generates new manifest files describing those changes.
- **expire_snapshots** removes old snapshots and updates the metadata layer, producing more manifest entries.
- **remove_orphan_files** sweeps unreferenced files and modifies table metadata.

If you ran `rewrite_manifests` first, you'd consolidate 50,000 manifests into 5 large ones. Then compaction runs and generates hundreds of new manifests. Expire and orphan cleanup generate more. Your consolidation pass is immediately invalidated — next week you're back to 50,000 manifests.

By running `rewrite_manifests` last, you consolidate the manifest set that already reflects a compacted, expired, cleaned table. One pass per week is sufficient.

## The ordering is efficiency, not safety

**Reversing the order doesn't break anything or cause data loss.** Iceberg's atomic commit semantics guarantee:
- `expire_snapshots` will never delete a file referenced by any live snapshot, regardless of order
- `remove_orphan_files` will never touch a file that any snapshot points to

The only cost of reversing the order is operational: cleanup gets spread across two maintenance cycles instead of one. Same eventual end state, just deferred. The canonical ordering exists purely to maximize cleanup per maintenance window.

## The complete weekly maintenance schedule

```
1. rewrite_data_files  — nightly (compaction: fix data-file bloat)
2. expire_snapshots    — weekly (free old snapshot references)
3. remove_orphan_files — weekly (sweep files freed by expired snapshots)
4. rewrite_manifests   — weekly, LAST (consolidate now-stable metadata index)
```

## Quick check: do you even need manifest rewriting?

```sql
-- Count your current manifest files in Trino
SELECT COUNT(*) AS manifest_count
FROM iceberg.analytics."events$manifests";
```

- **< 10 manifests** — no action needed
- **10–50** — optional; table is probably fine
- **50–200** — worth doing if query planning is slow
- **200+** — almost certainly degrading every query; prioritize

## Why compaction alone doesn't fix this

Compaction fixes data-file bloat (merging tiny Parquet files into large ones). `rewrite_manifests` fixes metadata-file bloat (merging tiny manifest files into large ones). They fix different problems — a table can have healthy large data files but thousands of small manifest files, and Trino still spends 30 seconds planning before reading any data. You need both operations.

**Resources cited:** `/Users/hclin/github/recknihao/resources/17-iceberg-table-maintenance.md`
