# Answer to Q2: Column DROP Through Debezium CDC into Iceberg (Iter 348)

Dropping the column in Postgres **does NOT automatically drop it from the Iceberg table**. You need to act explicitly, and historical data is safe — but only within your snapshot-retention window.

## On the Debezium side

Debezium handles the schema change automatically. When `legacy_metadata` is dropped from Postgres, the next DML statement (INSERT, UPDATE, DELETE) on that table generates a WAL RELATION message describing the updated column layout. Debezium reads this and stops including `legacy_metadata` in events from that point forward. No connector restart required, no error thrown — the column simply disappears from new events.

## On the Iceberg side — you need to act

The Iceberg table keeps `legacy_metadata` indefinitely until you explicitly drop it. What happens if you don't:

- New events from Debezium arrive without the `legacy_metadata` field.
- Your Spark consumer's MERGE INTO throws an `AnalysisException` — schema mismatch between the source events (no `legacy_metadata`) and the Iceberg target (still expects it).
- The streaming job stalls and retries in a loop until you fix the schema.

## The runbook: pause → ALTER → resume

**Step 1: Pause the Spark consumer**
```bash
kubectl scale deployment spark-events-consumer --replicas=0
```
Debezium keeps running and buffers events in Kafka (7-day retention).

**Step 2: Drop the column from Iceberg** (metadata-only, milliseconds)
```sql
-- Run in Trino or Spark SQL:
ALTER TABLE iceberg.analytics.events DROP COLUMN legacy_metadata;
```

Iceberg's field-ID-based schema tracks the drop internally. Existing Parquet files are not modified — the bytes for `legacy_metadata` are still physically on disk.

**Step 3: Resume the consumer**
```bash
kubectl scale deployment spark-events-consumer --replicas=1
```
Events flow normally. New rows have NULL for `legacy_metadata` (because it no longer exists in Postgres); old rows retain the original values in the Parquet files.

**Total downtime: under 60 seconds.**

## What happens to historical data

Historical data for `legacy_metadata` is **still there in the Parquet files**. After the DROP:

- Normal queries (`SELECT *`) will no longer show `legacy_metadata` — the column is gone from the schema.
- **Time-travel queries can still access the old data** for snapshots that existed before the DROP:
  ```sql
  SELECT id, legacy_metadata, event_ts
  FROM iceberg.analytics.events FOR VERSION AS OF <snapshot_id_before_drop>;
  ```

This works because Iceberg tracks columns by stable field IDs — historical files still have the bytes.

**However**, this window is bounded by snapshot retention. Once you run `expire_snapshots` and old snapshots are purged (typically after 7 days on this stack), the time-travel path to that data closes permanently. The Parquet files themselves may eventually be cleaned up by `remove_orphan_files` if no live snapshot references them.

If you need to preserve the historical `legacy_metadata` data long-term, export it to a separate table before running maintenance.

**Resources cited:** `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md`
