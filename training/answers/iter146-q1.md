# Iter 146 Q1 — Spark Structured Streaming Crash Recovery

## Answer

When a Spark Structured Streaming job crashes mid-batch, what happens on restart depends entirely on whether you configured a checkpoint location — and whether your Iceberg write is structured for idempotency.

### Checkpointing is mandatory

Spark's fault-tolerance mechanism is the checkpoint directory. This must live in durable storage, not on pod ephemeral disk. In your on-prem setup, that means MinIO:

```python
query = (
    df.writeStream
    .format("iceberg")
    .outputMode("append")
    .option("checkpointLocation", "s3a://lakehouse/streaming-checkpoints/events-pipeline")
    .trigger(processingTime="30 seconds")
    .toTable("iceberg.analytics.events")
)
```

The checkpoint stores three things:
1. **Kafka offsets** — exactly which offsets have been committed to Iceberg
2. **Batch metadata** — which micro-batch ID was last successfully committed
3. **Write-ahead log** — in-flight output file locations for the current batch

If the checkpoint is on the pod's local disk and the pod is killed and rescheduled on a different node, you lose the checkpoint and Spark has no way to know where it left off.

### At-least-once delivery from Kafka

When you restart the job with the checkpoint intact, Spark replays from the last successfully committed Kafka offset. This guarantees you will **not miss events** — but you may **re-read events** that were read in the crashed batch. This is called at-least-once delivery. You will not miss data, but duplicates are possible if the batch crashed after reading from Kafka but before successfully committing to Iceberg.

### Making it idempotent with MERGE INTO

The standard fix for at-least-once duplicates is to make the write idempotent. Instead of a blind append, use a MERGE that deduplicates on a natural key:

```python
def write_batch(batch_df, batch_id):
    batch_df.createOrReplaceTempView("incoming_events")
    batch_df.sparkSession.sql("""
        MERGE INTO iceberg.analytics.events AS target
        USING incoming_events AS source
        ON target.event_id = source.event_id
        WHEN NOT MATCHED THEN INSERT *
    """)

query = (
    kafka_df.writeStream
    .foreachBatch(write_batch)
    .option("checkpointLocation", "s3a://lakehouse/streaming-checkpoints/events-pipeline")
    .trigger(processingTime="30 seconds")
    .start()
)
```

With this pattern:
- **First run** (no duplicate): event is inserted normally
- **Replay run** (duplicate from replay): `ON target.event_id = source.event_id` matches, `WHEN NOT MATCHED` clause does nothing — the duplicate is silently dropped

### The half-written state question

Iceberg's atomic commit model protects you here. Spark writes Parquet data files to a staging area and only commits the Iceberg snapshot (the pointer swap in the metadata) after all files are successfully written. If the job crashes mid-batch:

- The Parquet files for that incomplete batch are orphaned in the staging area — they exist on disk but are not referenced by any snapshot
- The current Iceberg snapshot is unchanged — it still points to the last successfully committed batch
- Any queries running against the table during the crash see the previous clean snapshot — no half-written rows, no partial data

On restart, Spark sees the checkpoint says batch N-1 committed and replays batch N from scratch, writing fresh Parquet files and committing a new snapshot.

The orphaned files from the crash are cleaned up by Iceberg's `remove_orphan_files` maintenance procedure.

### Verification after restart

Check that the streaming job picked up the right checkpoint:

```sql
-- Confirm the last successful snapshot timestamp
SELECT snapshot_id, committed_at, operation, summary
FROM iceberg.analytics.events$snapshots
ORDER BY committed_at DESC
LIMIT 5;
```

Check Kafka consumer group lag:
```bash
kafka-consumer-groups.sh --bootstrap-server kafka1:9092 \
  --group spark-events-pipeline --describe
```

A lag of 0 means Spark has caught up. If there is lag after restart, it is processing replay — this is expected and will drain.

### Summary

| Scenario | What happens |
|---|---|
| No checkpoint configured | On restart, Spark re-reads from Kafka `auto.offset.reset` policy — likely `latest`, so events during downtime are lost |
| Checkpoint on pod local disk | Checkpoint lost when pod is rescheduled — same as no checkpoint |
| Checkpoint in MinIO + blind append | Duplicates inserted on replay |
| Checkpoint in MinIO + MERGE INTO on event_id | Exactly-once effective behavior — duplicates silently dropped, no missing events, no half-written state |

The combination of MinIO checkpoint + MERGE INTO idempotency is the standard pattern for production Spark Structured Streaming jobs writing to Iceberg.
