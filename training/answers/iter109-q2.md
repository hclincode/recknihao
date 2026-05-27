# Iter109 Q2 — Answer

**Question**: We're using Debezium to capture changes from Postgres and writing them into Iceberg. The pipeline works fine for normal INSERT/UPDATE activity, but we have a batch job that runs every Sunday night and does a bulk DELETE — it removes about 2 million rows of expired trial data from Postgres all at once. After the next Spark job runs, Trino queries against that Iceberg table are noticeably slower for a day or two before eventually recovering. What's happening under the hood, and is there something we should do differently to handle large bulk deletes so the table stays performant?

---

## Answer

### What's happening under the hood

When Debezium captures a bulk DELETE of 2 million rows from Postgres, it streams individual DELETE events to Kafka (one event per deleted row). Your Spark job applies these to the Iceberg table. Here's the performance impact:

**In Iceberg, DELETE is not an immediate data rewrite — it's a marker file operation.** Instead of removing rows from existing Parquet files, Iceberg writes small **delete files** (positional markers saying "row N in data file X should be ignored"). These markers accumulate, and the underlying Parquet files are left untouched. When Trino runs a query, it must:

1. Read the Parquet data files
2. Read all the delete files accumulated since the last compaction
3. Apply the deletes at query time (rows marked as deleted are filtered out during scan)

With 2 million delete markers written at once, Trino's query planner has to evaluate them all on every query — this is the 24–48 hour slowness you're seeing.

**The slowness recovers** when your nightly compaction job runs `rewrite_data_files`. Compaction reads the Parquet files affected by delete markers, drops the deleted rows, writes new clean Parquet files, and removes the delete files in the process.

### Why bulk Debezium deletes are especially painful

Debezium captures `DELETE FROM expired_trials WHERE ...` as 2 million individual DELETE events — one per row. Your Spark job writes 2 million delete markers in a single batch. Delete markers are cheap to write (instant), but expensive to evaluate at query time (every file must be read). Bulk deletes create the worst case: many markers all at once, hitting query time before compaction can clean them up.

### Diagnosis: confirm it's delete markers

```sql
-- Run in Trino to see current delete file count
SELECT COUNT(*) AS delete_file_count
FROM iceberg.analytics."expired_trials$files"
WHERE file_type = 'POSITION_DELETE';
```

If this spiked after Sunday's delete job, delete markers are the cause. After compaction runs, this should drop to zero.

### Solution 1: Compact immediately after the bulk delete (quickest fix)

Instead of waiting for nightly compaction, trigger it right after the bulk delete job completes. This closes the slowness window from 24–48 hours to a few minutes (compaction time):

```python
# Run in Spark immediately after the Debezium CDC writes complete on Sunday night
spark.sql("""
    CALL iceberg.system.rewrite_data_files(
        table => 'analytics.expired_trials',
        options => map('target-file-size-bytes', '268435456')
    )
""")

# Then expire old snapshots so MinIO can reclaim the old files
spark.sql("""
    CALL iceberg.system.expire_snapshots(
        table => 'analytics.expired_trials',
        older_than => current_timestamp - interval '1' day,
        retain_last => 5
    )
""")
```

Schedule this Spark job for Monday at 2 AM (after the Sunday bulk delete completes), so the slowness happens during off-peak hours rather than during business hours.

### Solution 2: Soft deletes (recommended long-term)

The production-grade pattern is to avoid hard deletes in the hot path entirely:

**In Postgres**: change your batch job from:
```sql
DELETE FROM expired_trials WHERE trial_end < now() - interval '30 days';
```
to:
```sql
UPDATE expired_trials SET deleted_at = now() WHERE trial_end < now() - interval '30 days';
```

**In Trino**: add a view that filters out deleted rows:
```sql
CREATE VIEW tenant_acme.active_trials AS
  SELECT * FROM iceberg.analytics.expired_trials
  WHERE deleted_at IS NULL;
```

Debezium captures this as UPDATE events rather than DELETE events. Iceberg handles UPDATEs with fewer delete markers than hard DELETEs (updates are a delete + insert internally, but in a controlled pattern). Application queries hit the view and never see deleted rows.

**Weekly reconciliation** (scheduled maintenance window, e.g., Sunday 3 AM):
```python
# Physically remove soft-deleted rows from Iceberg
spark.sql("""
    DELETE FROM iceberg.analytics.expired_trials
    WHERE deleted_at IS NOT NULL
""")

# Compact to apply the deletes
spark.sql("""
    CALL iceberg.system.rewrite_data_files(
        table => 'analytics.expired_trials'
    )
""")

# Expire snapshots and clean orphans
spark.sql("""
    CALL iceberg.system.expire_snapshots(
        table => 'analytics.expired_trials',
        older_than => current_timestamp - interval '7' day,
        retain_last => 5
    )
""")

spark.sql("""
    CALL iceberg.system.remove_orphan_files(
        table => 'analytics.expired_trials',
        older_than => current_timestamp - interval '3' day
    )
""")
```

The cleanup runs in a scheduled maintenance window so the physical delete + compaction cost never hits production query traffic.

### Solution 3: Pre-schedule compaction right after the Sunday job

If the Sunday bulk delete is predictable in timing, simply schedule Spark compaction for 30 minutes after the bulk delete completes. This is the lowest-effort change: no schema changes, no application changes — just a scheduled Spark job that runs compaction after the problematic delete batch.

### Which to choose

| Approach | Effort | Slowness window | Best for |
|---|---|---|---|
| Compact immediately after delete | Low | Minutes | Quick fix, existing pipeline |
| Pre-schedule Monday 2am compaction | Low | During off-peak only | Predictable weekly batch |
| Soft deletes + weekly reconciliation | Medium | None (controlled) | Long-term production pattern |

For your immediate problem: add a compaction job that runs Monday morning. For the long term: adopt soft deletes so bulk deletions never generate a wall of delete markers against live query traffic.
