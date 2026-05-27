# Answer to Q2: Deleting Orphaned Rows from Iceberg After EXCEPT Detection (Iter 337)

Yes, `DELETE FROM ... WHERE id IN (...)` is valid Iceberg syntax. But there's a critical three-step sequence you need to follow — Iceberg's immutable file architecture means a DELETE doesn't immediately free storage the way it does in Postgres.

## The three-step sequence

**Step 1: Issue the DELETE statement**

```sql
-- This creates "delete files" — small marker files that say which rows to ignore.
-- The underlying Parquet data files are NOT rewritten yet.
DELETE FROM iceberg.analytics.events
WHERE event_id IN (
  SELECT event_id FROM iceberg.analytics.events
  EXCEPT
  SELECT event_id FROM postgres_catalog.events
);
```

At this point, the rows are hidden from queries, but they're not physically removed from MinIO. The bytes are still there.

**Step 2: Compact to apply the deletes**

```sql
-- Spark SQL syntax
CALL iceberg.system.rewrite_data_files(
  table => 'analytics.events',
  options => map('target-file-size-bytes', '268435456')  -- 256 MB
);
```

This rewrites every data file that contains a deleted row, excluding the deleted rows. Storage usage may briefly *grow* at this point because the old files are still on MinIO — they're just no longer referenced by the current snapshot.

**Step 3: Expire old snapshots (CRITICAL — do not skip)**

```sql
-- Spark SQL syntax
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.events',
  older_than  => current_timestamp() - interval '7' day,
  retain_last => 1
);
```

Only this step physically removes the old bytes from MinIO. After Step 2, the old data files are only referenced by *prior* snapshots. This call removes those old snapshots, making the files eligible for deletion from MinIO.

## If you prefer to stay in Trino

```sql
-- Trino 467: Issue the DELETE
DELETE FROM iceberg.analytics.events
WHERE event_id IN (...);

-- Trino 467: Compact
ALTER TABLE iceberg.analytics.events EXECUTE optimize;

-- Trino 467: Expire snapshots
-- IMPORTANT: Trino 467 enforces a 7-day minimum retention floor
ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '7d');
```

Note: Trino 467 enforces a 7-day minimum on `expire_snapshots`. If you need to physically purge rows faster (e.g., GDPR right-to-be-forgotten), use the Spark form, which has no floor.

## Why all three steps are required

- Skip Step 3: storage never actually drops (old files still referenced by prior snapshots)
- Skip Step 2: queries become slower because Iceberg reads data files AND applies delete markers at query time
- Iceberg's immutable-file architecture means you cannot delete a file unless no snapshot points to it

## Between steps 1 and 2

Your queries will be temporarily slower because Iceberg has to apply delete markers at query time. Once `rewrite_data_files` completes, the delete files are baked into new data files and query speed returns to normal.

**Resources cited:** `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md`, `/Users/hclin/github/recknihao/resources/17-iceberg-table-maintenance.md`
