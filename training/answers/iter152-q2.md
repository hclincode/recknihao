# Iter 152 Q2 — Iceberg Partition Evolution: Month to Day on a Live Table

## Answer

Yes — you can change partitioning on a live Iceberg table without rewriting existing data or taking downtime. Iceberg handles old and new partition layouts simultaneously. But old files won't automatically get re-laid-out on the new spec unless you explicitly rewrite them. If you skip that step, old data stays slow forever.

### Step 1: Change the partition spec for new writes (instant, metadata-only)

```sql
-- Trino syntax
ALTER TABLE iceberg.analytics.events
SET PROPERTIES partitioning = ARRAY['day(event_date)', 'tenant_id'];
```

This is a fast, safe, metadata-only operation. It completes in milliseconds and the table remains fully queryable during and after. All writes from this point forward land in day-level partition directories.

After this ALTER, Iceberg tracks two separate partition specs:
- **Old files (pre-ALTER)**: partitioned by month — readable but day-level queries scan the entire month
- **New files (post-ALTER)**: partitioned by day + tenant — day queries prune correctly and scan only the right day

### Step 2: Rewrite historical files to the new spec (the step teams skip and regret)

The ALTER above does not touch your 2 years of existing data. Without this step, old data stays slow indefinitely. To physically migrate old files to day-level partition layout:

```sql
-- Spark SQL only (run via spark-submit or spark-sql — NOT Trino)
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.events',
  options => map(
    'rewrite-all',            'true',        -- force rewrite ALL files, not just small ones
    'target-file-size-bytes', '268435456'    -- 256 MB target file size
  )
);
```

`rewrite-all=true` is required here. The default compaction strategy skips well-sized files. Your month-partitioned files are probably already large, so without this flag compaction skips them and leaves them in the old month layout.

On a 2-year table, expect 2–8 hours depending on cluster size. Schedule during a low-traffic window. Live queries continue working throughout — no locking, no downtime.

**Use Spark, not Trino, for this step.** Trino has known bugs in post-partition-evolution compaction (trinodb/trino #26109, #26503, #25279) that can produce files with incorrect partition values. Spark's `rewrite_data_files` with `rewrite-all=true` is the correct and safe approach.

### Step 3: Clean up old snapshots and files

After the rewrite, the old month-partitioned Parquet files are unreferenced but still on MinIO. Free up storage:

```sql
-- Trino 467 form
ALTER TABLE iceberg.analytics.events
EXECUTE expire_snapshots(retention_threshold => '7d');

-- Or Spark form with more control
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.events',
  older_than  => current_timestamp() - interval '7' day,
  retain_last => 5
);
```

### How Iceberg handles both layouts simultaneously

Iceberg tags every data file with a `spec_id` (an integer identifying which partition spec was active when the file was written). When a query runs, the engine:
1. Checks the spec_id for each file
2. Applies the appropriate pruning rules to each spec's files
3. Merges the result sets

This is transparent — your SQL stays the same. A query like:
```sql
SELECT COUNT(DISTINCT user_id)
FROM iceberg.analytics.events
WHERE tenant_id = 'acme'
  AND event_date >= DATE '2026-05-22' AND event_date < DATE '2026-05-25'
```
works correctly whether it hits month-partitioned or day-partitioned files. Old month files just won't prune as precisely — they scan the whole month's data for a 3-day request.

### Verify the migration is complete

After rewrite + expiry, confirm all old-spec files are gone:

```sql
SELECT spec_id, COUNT(*) AS file_count
FROM iceberg.analytics."events$files"
GROUP BY spec_id;
```

When the old `spec_id` (usually 0) shows 0 files, migration is complete. Until then, those files still exist under the old month layout.

### Important caveats

**Temporary storage spike**: During rewrite, MinIO temporarily holds both old and new files. Expect ~2x the table size to be consumed for a few hours before expiry cleanup. Plan for storage headroom.

**Partition spec changes are write-forward only**: The ALTER only affects new writes. Old data stays in the old layout until explicitly rewritten. Teams that skip step 2 notice after 3+ months that their "historical" queries still run slowly.

**Hidden partitioning**: Iceberg's partition pruning is automatic — you never write `WHERE $partition = 'day=2026-05-24'` in SQL. The engine infers which files to scan from the WHERE clause on normal columns. Make sure `event_date` in the WHERE clause is the same column the partition spec is built on (`day(event_date)`), not a derived value like `DATE(event_timestamp)` from a different column.

### Timeline for your 2-year table

| Step | Time | What changes |
|---|---|---|
| ALTER TABLE SET PROPERTIES | 5 minutes | New writes go to day partitions |
| rewrite_data_files (Spark) | 2–8 hours | Old data migrated to day partitions |
| expire_snapshots | 30 minutes | Old files deleted from MinIO |
| Single-day queries become fast | After step 3 | Day pruning now applies to all data |
