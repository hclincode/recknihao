# Iter 148 Q1 — Iceberg Small File Compaction

## Answer

Yes — this is a known and expected problem with streaming writes to Iceberg. Every 30-second Spark Structured Streaming micro-batch creates a new Parquet file. At 2,880 micro-batches per day (every 30 seconds × 24 hours), 80,000 small files after 3 weeks is exactly what you'd expect.

**The performance impact is classic:** each Parquet file has 10–50 ms metadata overhead to open. With 80,000 files, your query spends most of its time opening files and reading footers before touching any data — that's why 4–5 second queries became 30–40 seconds.

### The solution: Iceberg compaction

You do not need to take the table offline or lose data. Iceberg is immutable — compaction is a safe, background operation that:
1. Merges many small files into fewer large files (~256 MB each)
2. Creates a new snapshot pointing to the merged files
3. Leaves old snapshots intact so running queries continue uninterrupted

80,000 files at under 1 MB average would compact down to roughly 100–150 files at ~256 MB each. Queries that scan a date range would then open 5–10 files instead of thousands.

### Immediate fix (ad-hoc compaction from Trino)

```sql
ALTER TABLE iceberg.analytics.events EXECUTE optimize(file_size_threshold => '128MB');
```

This runs synchronously in Trino and takes 10–60 minutes depending on cluster size. During compaction, queries continue running against the current snapshot — they see the old small files. When compaction finishes, the next queries see the compacted result. Your 30–40 second queries should return to 4–5 seconds after this completes.

### Long-term fix: scheduled maintenance

Streaming tables need ongoing compaction or the problem returns. The full maintenance sequence has four operations that must run in this order (order matters for safety):

**Nightly (e.g., 4 AM, after your ingestion finishes) — run from Spark:**

```sql
-- Spark SQL (via spark-submit or Airflow DAG)
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.events',
  options => map(
    'target-file-size-bytes', '268435456',  -- 256 MB per file
    'min-input-files',        '5'           -- only compact partitions with 5+ files
  )
);
```

**Weekly (e.g., Sunday 3 AM, during a maintenance window) — run in order:**

```sql
-- 1. Expire old snapshots (frees snapshot references to old small files)
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.events',
  older_than  => current_timestamp - interval '30' day,
  retain_last => 10
);

-- 2. Remove orphan files (deletes unreferenced files from MinIO)
CALL iceberg.system.remove_orphan_files(
  table      => 'analytics.events',
  older_than => current_timestamp - interval '3' day
);

-- 3. Compact manifest files (reduces query planning overhead)
CALL iceberg.system.rewrite_manifests(
  table => 'analytics.events'
);
```

### Why this order matters

- **Compact first**: writes new large files; old small files remain on MinIO, still referenced by old snapshots
- **Expire snapshots**: removes old snapshot references to the small files; they are now unreferenced
- **Remove orphans**: deletes the unreferenced small files from MinIO
- **Rewrite manifests**: collapses metadata overhead

If you run remove_orphan_files before expire_snapshots, you risk deleting files that a snapshot is still referencing.

### Storage behavior during maintenance

Compaction by itself does not shrink MinIO storage immediately:
- After compaction runs: storage temporarily grows (~150% of original — old small files still exist alongside new large files)
- After expire_snapshots + remove_orphan_files run: storage drops to just the compacted size (~38 GB for 80,000 × 1 MB files)

The storage drop appears after the full sequence, not right after compaction.

### Trino 467 vs Spark syntax

The maintenance procedures have different syntax depending on which engine you use:

| Operation | Spark CALL form | Trino 467 form |
|---|---|---|
| Compaction | `CALL iceberg.system.rewrite_data_files(...)` | `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '128MB')` |
| Expire snapshots | `CALL iceberg.system.expire_snapshots(...)` | `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '30d')` |
| Remove orphans | `CALL iceberg.system.remove_orphan_files(...)` | `ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold => '7d')` |
| Manifest rewrite | `CALL iceberg.system.rewrite_manifests(...)` | `ALTER TABLE ... EXECUTE optimize_manifests` |

**Important**: Trino 467 enforces a 7-day minimum retention floor on `expire_snapshots` and `remove_orphan_files`. Trino will reject any value below 7 days with an error. If you need sub-7-day retention (e.g., for GDPR right-to-erasure), run the CALL forms from Spark instead — Spark has no floor.

### Recommended schedule going forward

```
Nightly (4 AM):    Spark rewrite_data_files — target 256 MB, min 5 input files
Weekly (Sun 3 AM): expire_snapshots → remove_orphan_files → rewrite_manifests
```

Without ongoing maintenance, a streaming table ingesting every 30 seconds will see:
- **Week 3–4**: queries slow as file count rises
- **Week 5–6**: manifest planning adds 10+ seconds to every query
- **Week 9+**: ingestion jobs begin failing due to metadata overhead

### Action items

**Today**: Run the ad-hoc `ALTER TABLE ... EXECUTE optimize` from Trino to get back to 4–5 second queries.

**This week**: Schedule the nightly Spark compaction job (rewrite_data_files) for 4 AM.

**Next week**: Add the weekly maintenance window (Sunday 3 AM: expire → remove orphans → rewrite manifests).
