# Iter 155 Q1 — Debezium CDC Pipeline: Postgres WAL to Iceberg

## Answer

## How CDC Captures Deletes from Postgres into Iceberg

Your current batch approach (`updated_at`-based incremental) **cannot** capture hard deletes — a deleted row leaves no trace. A CDC (Change Data Capture) pipeline solves this by reading Postgres's transaction log directly.

### The Pipeline Components

1. **Postgres Write-Ahead Log (WAL)** — Every change (INSERT, UPDATE, DELETE) is written here for crash recovery. CDC taps into this log.

2. **Debezium** — A connector that reads the WAL and emits each row change as a structured event with three pieces of information:
   - `op`: the operation type (`c` = INSERT, `u` = UPDATE, `d` = DELETE, `r` = snapshot/bulk read)
   - `before`: the row's old state (populated for DELETE and UPDATE)
   - `after`: the row's new state (populated for INSERT, UPDATE, and snapshot reads)

3. **Kafka** — A durable message queue holding those change events. Kafka decouples Debezium (the producer) from your Spark consumer, so if Spark lags, Kafka buffers the backlog.

4. **Spark Structured Streaming** — A long-running Spark job that reads from Kafka in micro-batches (e.g., every 60 seconds) and applies changes to your Iceberg table using `MERGE INTO`.

5. **Iceberg table** — The destination, where each row change becomes an atomic commit.

### Postgres Prerequisites (Required Setup)

Before Debezium can read your WAL, configure these on Postgres:

**In `postgresql.conf`:**
```ini
wal_level = logical            # default is 'replica'; logical adds metadata Debezium needs
max_wal_senders = 10           # at least one per Debezium connector
max_replication_slots = 10     # at least one per Debezium connector
```
This requires a Postgres restart.

**Create a replication role:**
```sql
CREATE ROLE debezium_user WITH LOGIN REPLICATION PASSWORD '...';
GRANT CONNECT ON DATABASE app TO debezium_user;
GRANT USAGE ON SCHEMA public TO debezium_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO debezium_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO debezium_user;
```

**Set `REPLICA IDENTITY FULL` on every table you replicate:**
```sql
ALTER TABLE users REPLICA IDENTITY FULL;
ALTER TABLE orders REPLICA IDENTITY FULL;
```

This is critical for deletes. By default, Postgres only logs the primary key in the WAL for DELETE operations — Debezium's `before` image contains **only the PK, with every other column NULL**. `REPLICA IDENTITY FULL` tells Postgres to log all columns. The cost is roughly 2x WAL volume for write-heavy tables, but it's essential for full pre-delete row state.

**Create a publication and replication slot:**
```sql
CREATE PUBLICATION debezium_pub FOR ALL TABLES;
SELECT pg_create_logical_replication_slot('debezium_slot', 'pgoutput');
```

**In `pg_hba.conf`, allow replication connections from Debezium:**
```
host    replication    debezium_user    10.0.0.0/8    md5
```

### The Spark Consumer: Parsing Debezium and Applying MERGE INTO

The correct approach uses `foreachBatch` to run `MERGE INTO` per micro-batch:

```python
from pyspark.sql.functions import col, from_json
from pyspark.sql.types import StructType, StructField, StringType, LongType

after_schema = StructType([
    StructField("event_id",    StringType()),
    StructField("tenant_id",   StringType()),
    StructField("user_id",     StringType()),
    StructField("event_name",  StringType()),
    StructField("occurred_at", LongType()),
])

def process_batch(batch_df, batch_id):
    if batch_df.isEmpty():
        return

    parsed = batch_df.select(
        from_json(col("value").cast("string"), StructType([
            StructField("op",     StringType()),
            StructField("after",  after_schema),
            StructField("before", after_schema),
        ])).alias("envelope")
    ).select("envelope.*")

    # INSERT, UPDATE, and snapshot reads all upsert the "after" image.
    upserts = parsed.filter(col("op").isin("c", "u", "r")).select("after.*")
    if not upserts.isEmpty():
        upserts.createOrReplaceTempView("cdc_upserts")
        spark.sql("""
            MERGE INTO iceberg.analytics.events t
            USING cdc_upserts s ON t.event_id = s.event_id
            WHEN MATCHED THEN UPDATE SET *
            WHEN NOT MATCHED THEN INSERT *
        """)

    # DELETEs: match on the "before" primary key and remove the row.
    deletes = parsed.filter(col("op") == "d").select("before.event_id")
    if not deletes.isEmpty():
        deletes.createOrReplaceTempView("cdc_deletes")
        spark.sql("""
            MERGE INTO iceberg.analytics.events t
            USING cdc_deletes s ON t.event_id = s.event_id
            WHEN MATCHED THEN DELETE
        """)

query = (
    spark.readStream
        .format("kafka")
        .option("kafka.bootstrap.servers", "kafka:9092")
        .option("subscribe", "postgres.public.events")
        .option("startingOffsets", "latest")
        .load()
    .writeStream
        .foreachBatch(process_batch)
        .option("checkpointLocation", "s3a://lakehouse/streaming-checkpoints/events")
        .trigger(processingTime="60 seconds")
        .start()
)
query.awaitTermination()
```

**Key points:**
- The `op` field distinguishes DELETE (`"d"`) from INSERT (`"c"`), UPDATE (`"u"`), and snapshot reads (`"r"`).
- For DELETE, match on the primary key in the `before` image.
- The `foreachBatch` escape hatch is necessary because `MERGE INTO` cannot run through a bare `.format("iceberg").writeStream` — that only supports append mode.
- Iceberg 1.5.2 **requires a minimum 60-second trigger interval** for streaming writes.
- The checkpoint directory must live in MinIO (`s3a://...`), not in a worker pod's ephemeral disk.

### What Happens if the Pipeline Falls Behind

**Layer 1: Debezium to Kafka**

Debezium reads the WAL and publishes to Kafka. Debezium will not lose events — it advances a Postgres replication slot only after successfully publishing to Kafka. However, if Debezium blocks, Postgres WAL accumulates. Monitor the replication slot lag:

```sql
SELECT slot_name, active, restart_lsn,
       pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS slot_lag_bytes
FROM pg_replication_slots;
```

If `slot_lag_bytes` exceeds a threshold (e.g., 10 GB), alert and investigate. An unread slot fills the Postgres WAL disk and stalls the primary — a production incident.

**Layer 2: Kafka to Spark**

Spark's `readStream` consumes Kafka. If Spark lags, messages pile up in Kafka (which is designed to hold them). Spark will **eventually catch up** through subsequent micro-batches — there is no data loss, only latency. Spark's checkpoint (stored in MinIO) tracks exactly which Kafka offset it has processed.

**Layer 3: MERGE INTO contention**

During a traffic spike, concurrent MERGE operations can conflict with compaction. Iceberg retries automatically (default 4 retries with exponential backoff). If all retries fail, the Spark job fails — but this is **not data loss**. On restart, Spark replays the failed batch from its checkpoint.

To mitigate: schedule compaction outside the ingestion window. Raise `commit.retry.num-retries` to 8–12 on the Iceberg table.

### Data Loss Scenarios

**Will NOT lose events:**
- Kafka lag (buffered; Spark catches up)
- Spark pod restarts (checkpoint recovers offsets)
- Postgres replication slot fills (Postgres slows, not silent loss)

**Will lose events in these rare cases:**
- **Kafka topic deleted or re-created** — old messages are gone
- **Kafka retention expires** before Spark has consumed the messages — mitigate: set high retention on the CDC topic (e.g., 30 days) and monitor consumer lag aggressively
- **Debezium's `connect-offsets` topic is wiped** — Debezium re-snapshots from scratch, causing duplicate INSERTs (not loss, but disruptive)

### State and Progress Tracking

A CDC pipeline tracks progress in **three independent places**:

1. **Debezium source offsets** (Kafka `connect-offsets` topic) — "Which WAL LSN did Debezium publish to Kafka?"
2. **Postgres replication slot** (`pg_replication_slots`) — "Which WAL can Postgres safely discard?"
3. **Spark consumer checkpoint** (MinIO) — "Which Kafka offset did Spark process?"

Deleting a Spark consumer group or checkpoint does NOT replay Debezium events — it only replays from Kafka. Debezium keeps publishing independently.

### Summary

| Concern | Answer |
|---|---|
| Can CDC capture hard deletes? | Yes — DELETE events carry the `before` primary key |
| Does the pipeline lose events during spikes? | No — Kafka buffers; Spark catches up |
| What's the real risk during spikes? | Postgres WAL disk fill if replication slot lags |
| What happens on Spark crash? | Checkpoint resumes from last committed Kafka offset |
