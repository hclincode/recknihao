# Iter116 Q1 — Answer

**Question**: We have a Postgres `events` table streaming into Iceberg via Debezium, and I'm noticing our Trino queries are getting noticeably slower week over week even though we haven't added much data volume. Someone on my team looked at the Iceberg metadata and said we have something like 40,000 "delete files" accumulating on the table, and suggested we need to run some kind of compaction. I don't fully understand the difference between running compaction that merges deletes versus just rewriting the whole table. Is there a point where having too many delete files actually tanks query performance, and how do I know when to run one type of compaction versus another?

---

## Answer

Yes, 40,000 delete files absolutely tanks query performance — at that count, queries can be 5–10× slower or hit timeouts. The good news: there are two targeted compaction procedures, and you can run the faster one right now from a Trino session without waiting for a scheduled Spark job.

### Why Delete Files Slow Queries

When Debezium streams changes from Postgres into Iceberg in merge-on-read (MoR) mode, every UPDATE and DELETE doesn't overwrite the Parquet data file — it writes a small **position delete file** that says "ignore these row positions in this data file." At query time, Trino must:

1. Open each Parquet data file
2. Open **every delete file** that applies to that data file
3. Merge all delete markers in memory to determine which rows are live

With 40,000 delete files spread across your table, this merge-at-read overhead dominates query time. You're spending most of your query budget on metadata operations before reading any actual data. The performance collapses non-linearly: 1,000 delete files adds noticeable latency; 10,000+ starts causing timeouts on complex queries; 40,000 is a severe operational issue.

### Diagnose First: Which Partitions Have the Problem

```sql
-- In Trino: count delete files per partition (no full table scan)
-- content column: 0=data files, 1=position delete files, 2=equality delete files
SELECT
  partition,
  COUNT(*) FILTER (WHERE content = 0) AS data_files,
  COUNT(*) FILTER (WHERE content = 1) AS position_delete_files,
  COUNT(*) FILTER (WHERE content = 2) AS equality_delete_files
FROM iceberg.analytics."events$files"
GROUP BY partition
HAVING COUNT(*) FILTER (WHERE content IN (1, 2)) > 100
ORDER BY position_delete_files DESC
LIMIT 20;
```

This shows you which partitions are most affected. Typically with CDC, the most recent few days have the highest delete-file counts (freshest ingestion window with the most recent updates).

### Two Compaction Strategies

**Strategy 1: Merge delete files only (surgical, fast — start here)**

`rewrite_position_delete_files` applies delete markers to their corresponding data files and writes new data files without the deleted rows. It doesn't touch data files that have no delete files. This is the right first move for a CDC table where most data files are fine and only delete files are the problem.

```python
# Spark (spark-submit or spark-sql)
spark.sql("""
    CALL iceberg.system.rewrite_position_delete_files(
        table   => 'analytics.events',
        options => map('delete-file-threshold', '1')
    )
""")
```

`delete-file-threshold=1` means: process any data file that has at least 1 delete file attached. This clears all 40,000 delete files from the table and produces new clean data files. Runtime: 30–90 minutes for your case. Query latency recovers immediately after.

**Strategy 2: Full compaction (heavier — use when data files are also fragmented)**

`rewrite_data_files` rewrites data files to consolidate small files AND applies pending delete files in one pass. Use this when a diagnostic query shows both many delete files AND many small data files per partition.

```python
spark.sql("""
    CALL iceberg.system.rewrite_data_files(
        table   => 'analytics.events',
        options => map(
            'target-file-size-bytes', '268435456',  -- 256 MB target
            'min-input-files',        '5',           -- only compact 5+ file partitions
            'delete-file-threshold',  '1'            -- apply deletes during rewrite
        )
    )
""")
```

| | `rewrite_position_delete_files` | `rewrite_data_files` |
|---|---|---|
| Targets | Delete files only | Data files + delete files |
| Speed | Fast (small files only) | Slow (rewrites large data files) |
| Best for | CDC with clean data files | Fragmented data + many deletes |
| Snapshot history | Preserved | Preserved |

### Ad-Hoc Fix Right Now (Trino-Native)

If your dashboards are slow right now, don't wait for a Spark job. From any Trino session:

```sql
-- Trino 467 native compaction — applies deletes and consolidates small files
-- Equivalent to rewrite_data_files; runs directly in Trino session
ALTER TABLE iceberg.analytics.events
EXECUTE optimize(file_size_threshold => '128MB');
```

This should bring query latency back within 5–30 minutes depending on table size.

### Production Maintenance Schedule

Set up both a nightly and weekly job (Airflow, Kubernetes CronJob, or spark-submit):

```sql
-- NIGHTLY (4 AM, after Debezium ingestion completes)
-- For CDC tables: surgical delete-file compaction first
CALL iceberg.system.rewrite_position_delete_files(
    table   => 'analytics.events',
    options => map('delete-file-threshold', '1')
);

-- If data files are also small, add:
CALL iceberg.system.rewrite_data_files(
    table   => 'analytics.events',
    options => map(
        'target-file-size-bytes', '268435456',
        'min-input-files',        '5',
        'delete-file-threshold',  '1'
    )
);

-- WEEKLY (Sunday 3 AM)
-- 1. Expire old snapshots (unlocks old Parquet files for MinIO deletion)
CALL iceberg.system.expire_snapshots(
    table       => 'analytics.events',
    older_than  => current_timestamp() - INTERVAL '30' DAY,
    retain_last => 10
);

-- 2. Remove orphan files (Parquet files not referenced by any snapshot)
CALL iceberg.system.remove_orphan_files(
    table      => 'analytics.events',
    older_than => current_timestamp() - INTERVAL '3' DAY
);

-- 3. Compact manifests (reduces query planning overhead)
CALL iceberg.system.rewrite_manifests(table => 'analytics.events');
```

**Why this order matters:** Nightly compaction applies deletes and produces clean files. Weekly `expire_snapshots` removes old snapshots that still reference the pre-compaction delete files. Weekly orphan cleanup then physically removes those files from MinIO. Run out of order and the storage never actually shrinks.

### The Threshold That Should Trigger Compaction

| Delete file count per partition | Action |
|---|---|
| < 100 | Normal — no action needed |
| 100–1,000 | Monitor; schedule nightly compaction |
| 1,000–10,000 | Run `rewrite_position_delete_files` today; add nightly schedule |
| > 10,000 | Emergency: run ad-hoc from Trino (`EXECUTE optimize`) immediately |

At 40,000 total delete files (likely concentrated in recent partitions), you're past the emergency threshold. Run `EXECUTE optimize` now, then set up nightly compaction so this doesn't recur.
