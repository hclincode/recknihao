# Answer to Q2: Postgres CDC Exactly-Once Deduplication via source_lsn + MERGE INTO (Iter 329)

## How CDC Deduplication Works with Kafka Connect and Iceberg: The source_lsn + MERGE INTO Pattern

## The Problem: Why Duplicates Happen

When Kafka Connect with Debezium CDC crashes or restarts (pod reschedule, network blip, Kafka rebalance), it may re-deliver change events. Here's the scenario:

- Your Postgres database emits an UPDATE event at position X in the Write-Ahead Log (WAL).
- Kafka gets the event, but before Kafka Connect saves its offset (by default, every 60 seconds), the pod dies.
- On restart, Kafka replays the event from before the last committed offset — your Iceberg table sees the same database update twice.

## What source_lsn Actually Is

The `source_lsn` field comes from Debezium and represents the **Postgres WAL (Write-Ahead Log) position** where that change event originated. LSN (Log Sequence Number) is Postgres's WAL position, a strictly-increasing 64-bit integer. Debezium captures it into each change event's `source.lsn` field. **Higher LSN = later event** in Postgres's commit order.

This is the key insight: **LSN is strictly monotonic within a single Postgres instance**. Event with LSN=1000 always happened before event with LSN=2000, in wall-clock reality.

## Extracting source_lsn from the CDC Payload

First, you need to persist the LSN value into your Iceberg table. In your Spark job that consumes from Kafka, extract it from the Debezium JSON envelope:

```python
from pyspark.sql.functions import col, from_json

df = (
    spark.readStream
    .format("kafka")
    .option("kafka.bootstrap.servers", "kafka:9092")
    .option("subscribe", "postgres.public.events")
    .load()
)

df = (
    df
    .select(from_json(col("value").cast("string"), debezium_schema).alias("debezium_event"))
    .select(
        col("debezium_event.after.id").alias("id"),
        col("debezium_event.after.event_type").alias("event_type"),
        col("debezium_event.op").alias("op"),                    # 'c'=create, 'u'=update, 'd'=delete, 'r'=read
        col("debezium_event.source.lsn").alias("source_lsn"),    # Extract LSN from Debezium payload
    )
)
```

## The MERGE INTO Pattern: How Deduplication Happens

The `source_lsn` value guards your `WHEN MATCHED` branch — it prevents an older duplicate from overwriting a newer state:

```sql
MERGE INTO iceberg.analytics.events t
USING events_cdc_delta s
ON t.id = s.id
WHEN MATCHED AND s.op = 'd' THEN DELETE
WHEN MATCHED AND s.source_lsn > t.source_lsn THEN 
    UPDATE SET *
WHEN NOT MATCHED AND s.op IN ('c', 'r', 'u') THEN 
    INSERT *
```

Breaking this down:

- **`ON t.id = s.id`** — Join on the primary key: "Does this incoming change already exist in Iceberg?"
- **`WHEN MATCHED AND s.op = 'd'`** — If it's a DELETE from Postgres, remove the row.
- **`WHEN MATCHED AND s.source_lsn > t.source_lsn`** — **This is the deduplication guard.** Only update if the incoming change has a *newer* LSN than what we already stored. A duplicate with an older LSN is silently skipped.
- **`WHEN NOT MATCHED`** — If the row doesn't exist, insert it.

## Why This Prevents Duplicates

Imagine Kafka redelivers an UPDATE from LSN=500:

1. First run: You insert the row with LSN=500 into Iceberg.
2. Time passes, another UPDATE arrives with LSN=501, which overwrites the row and updates its `source_lsn` column to 501.
3. Kafka redelivers the old LSN=500 event due to a pod restart.
4. MERGE runs again with LSN=500 data. The row matches on `id`, so we hit `WHEN MATCHED`.
5. **The condition `s.source_lsn > t.source_lsn` evaluates to `500 > 501`, which is FALSE.**
6. None of the `WHEN MATCHED` branches execute — the row is left untouched with LSN=501 (the newer state).

## Before MERGE: Dedup at the Stream Level

The resource also recommends deduplicating *before* the MERGE, using a Spark window function. If your micro-batch from Kafka happens to contain multiple copies of the same event, remove duplicates first:

```python
from pyspark.sql import Window
from pyspark.sql.functions import col, row_number

w = Window.partitionBy("id").orderBy(col("source_lsn").desc())
events_dedup = (
    events_delta
    .withColumn("_rn", row_number().over(w))
    .filter(col("_rn") == 1)
    .drop("_rn")
)
events_dedup.createOrReplaceTempView("events_cdc_delta")
```

Then run the MERGE against the deduplicated view.

## Storing source_lsn Permanently

Your Iceberg table must have a `source_lsn` column:

```sql
CREATE TABLE iceberg.analytics.events (
    id              BIGINT,
    event_type      VARCHAR,
    occurred_at     TIMESTAMP(6),
    payload         VARCHAR,
    source_lsn      BIGINT,        -- Debezium WAL position; enables idempotency
    op              VARCHAR,
    ingested_at     TIMESTAMP(6)
)
```

This is cheap insurance — 8 bytes per row — and has a critical benefit: if CDC goes down and you need to recover, you can query Iceberg to find the last LSN that was successfully applied, so you know exactly where to resume from Postgres.

## A Critical Caveat: LSN is Per-Source

If you're pulling CDC from *two* Postgres instances (e.g., `postgres-us` and `postgres-eu`), **LSN values are NOT comparable across sources.** Their LSN spaces are independent. If you have a multi-source table, the composite key in your MERGE must include the source identifier:

```sql
MERGE INTO iceberg.analytics.events t
USING events_cdc_delta s
ON t.id = s.id AND t.source_region = s.source_region
WHEN MATCHED AND s.source_lsn > t.source_lsn THEN 
    UPDATE SET *
```

## Summary

The connection is: **`source_lsn` makes the MERGE idempotent by preventing older duplicates from overwriting newer state.** Without it, every duplicate would win on whichever order Spark happens to process them. With it, Kafka can redeliver as much as it wants — older events are automatically ignored.

**Resources cited:** `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md`
