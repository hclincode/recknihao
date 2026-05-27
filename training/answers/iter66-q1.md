# Iter66 Q1 — Answer

**Question**: We use Debezium to stream changes from Postgres into Kafka, and then a Spark job reads those Kafka events and writes them to Iceberg. The whole thing works okay for inserts and updates, but we just realized that when a row gets deleted in Postgres, Debezium sends a "tombstone" or delete event on the Kafka topic. Our current Spark job doesn't really handle that — it just skips events it doesn't recognize. So right now, if a customer deletes something in their account, the delete never makes it to Iceberg. The row just stays there forever. How are we supposed to apply deletes from Debezium into an Iceberg table? Is there a way to make those rows actually disappear from the lakehouse so that queries return accurate data, or are we stuck with something where deletes only get applied in a batch cleanup process?

---

## Answer

Your current setup has a real data accuracy problem — rows deleted in Postgres will accumulate in Iceberg forever until you handle the delete events. There are two paths forward, and which you choose depends on how real-time the deletes need to be.

### What Debezium delete events look like

Debezium represents every Postgres WAL event as a Kafka message with an `op` field:
- `op: "c"` — INSERT (create)
- `op: "u"` — UPDATE
- `op: "d"` — DELETE
- `op: "r"` — READ (snapshot)

For a DELETE, the message has the row's data in the `before` field (the row as it existed before deletion) and `null` in the `after` field. A tombstone is a separate follow-up message with a `null` value entirely — it signals Kafka log compaction to clean up the key. Your Spark job must handle both.

The primary key of the deleted row is always available in the `before` field of the `op: "d"` message. That's what you'll use to issue the corresponding Iceberg DELETE.

### Path A: Real-time delete propagation (Spark Structured Streaming)

Update your Spark Structured Streaming job to detect `op: "d"` events and issue `DELETE FROM` statements for each.

The pattern:

```python
from pyspark.sql import functions as F

# Read from Kafka
raw = spark.readStream.format("kafka") \
    .option("kafka.bootstrap.servers", "kafka:9092") \
    .option("subscribe", "postgres.public.events") \
    .load()

# Parse the Debezium envelope
parsed = raw.selectExpr("CAST(value AS STRING) as json_str") \
    .select(F.from_json("json_str", debezium_schema).alias("d")) \
    .select("d.op", "d.before.*", "d.after.*")

# Separate inserts/updates from deletes
upserts = parsed.filter(F.col("op").isin(["c", "u", "r"]))
deletes = parsed.filter(F.col("op") == "d")

# Write upserts to Iceberg using MERGE
def write_upserts(batch_df, batch_id):
    batch_df.createOrReplaceTempView("upsert_batch")
    spark.sql("""
        MERGE INTO iceberg.analytics.events t
        USING upsert_batch s ON t.event_id = s.event_id
        WHEN MATCHED THEN UPDATE SET *
        WHEN NOT MATCHED THEN INSERT *
    """)

# Write deletes to Iceberg using DELETE
def write_deletes(batch_df, batch_id):
    for row in batch_df.select("event_id").collect():
        spark.sql(f"""
            DELETE FROM iceberg.analytics.events
            WHERE event_id = {row.event_id}
        """)

upserts.writeStream.foreachBatch(write_upserts).start()
deletes.writeStream.foreachBatch(write_deletes).start()
```

This gives you near-real-time delete propagation — typically within a few seconds of the Postgres DELETE. Queries against Iceberg stop returning the deleted rows immediately after the Spark micro-batch processes the event.

### Path B: Soft-delete + batch cleanup (simpler, but delayed)

If real-time deletes aren't required (for example, analytics dashboards can tolerate a 24-hour lag), you can use a soft-delete pattern:

1. Add a `deleted_at TIMESTAMP` column to the Postgres source and your Iceberg table.
2. When a row is deleted in Postgres, mark it `deleted_at = now()` instead of a hard delete.
3. Your Spark ingestion job copies `deleted_at` into Iceberg.
4. All Trino views and queries filter `WHERE deleted_at IS NULL` to exclude soft-deleted rows.
5. A nightly batch job runs `DELETE FROM iceberg.analytics.events WHERE deleted_at < now() - interval '30' day` to purge old deleted rows.

This is simpler to implement but the "deleted" rows remain visible in Iceberg (with `deleted_at` set) until the batch runs. For GDPR hard-delete requirements, this is not sufficient on its own — you still need the physical purge sequence described below.

### Iceberg's delete mechanics: why a DELETE doesn't immediately remove bytes

This is the part that surprises most engineers coming from Postgres. When you issue `DELETE FROM iceberg.analytics.events WHERE event_id = 123`, Iceberg does **not** erase the row from the Parquet files. Instead, it creates a small **delete file** that records "skip row 123 from this file." The original Parquet data file is unchanged. This is Iceberg's **merge-on-read** (MoR) mode — reads apply delete files at query time to return the correct data.

MoR is fast for writes (no file rewrite) but adds read overhead as delete files accumulate. After many deletes, you need to compact.

### Compaction: keeping Iceberg healthy after streaming deletes

High-volume CDC deletes accumulate delete files. Without periodic compaction, read performance degrades (each query must merge many delete files) and storage grows.

Run this sequence nightly (via spark-submit, NOT Trino):

```sql
-- Step 1: Rewrite data files — applies accumulated deletes and produces clean Parquet files
CALL iceberg.system.rewrite_data_files(
  table    => 'analytics.events',
  strategy => 'binpack'
);

-- Step 2: Expire old snapshots — triggers actual S3/MinIO DELETE calls for unreferenced files
CALL iceberg.system.expire_snapshots(
  table        => 'analytics.events',
  older_than   => current_timestamp - interval '7' day,
  retain_last  => 10
);

-- Step 3: Remove orphan files — catches any failed-write residue
CALL iceberg.system.remove_orphan_files(
  table       => 'analytics.events',
  older_than  => current_timestamp - interval '1' day
);
```

**Critical ordering**: After step 1, storage temporarily *increases* (new files written before old ones are released). Only after step 2 does MinIO storage drop. Run them in order. Schedule this during off-peak hours when your ingestion job is not running — concurrent compaction and ingestion can cause commit conflicts.

### Which path is right for you?

| | Path A (real-time Structured Streaming) | Path B (soft-delete + batch) |
|---|---|---|
| **Delete lag** | Seconds | Up to 24 hours |
| **Complexity** | Higher (streaming job changes) | Lower |
| **GDPR compliance** | Yes (with nightly expire_snapshots) | Requires additional purge step |
| **Best for** | Customer-facing data with strict accuracy | Internal analytics, reporting |

Most SaaS analytics teams start with Path B and graduate to Path A when product requirements demand it. If your deleted data is customer account data subject to GDPR, Path A is the right choice — you want the row gone quickly and verifiably.

### Summary

- Your Spark job must check `op` field in Debezium events and issue `DELETE FROM iceberg.table WHERE pk = X` for `op: "d"` events.
- Iceberg's MoR mode makes these deletes fast at write time but accumulates delete files.
- Run nightly compaction (`rewrite_data_files` → `expire_snapshots` → `remove_orphan_files`) to keep performance healthy and reclaim storage.
- For GDPR, the physical purge requires `expire_snapshots` with aggressive retention settings — a `DELETE FROM` alone is not sufficient.
