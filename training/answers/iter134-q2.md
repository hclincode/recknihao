# Iter134 Q2 — Answer

**Question**: "We've had Debezium running for about six months — originally we set it up to replicate our Postgres events table to a second Postgres for read scaling. Now we're wondering whether we can use those same Debezium change events to keep our Iceberg analytics table current instead of running a nightly Spark batch job. I don't really understand what Debezium actually produces — is it just new rows, or does it include updates and deletes too? And if a user record in Postgres gets updated (say their plan changes from free to pro), how does that update actually get applied to the Iceberg table — does Iceberg support updating individual rows, or do we have to do something different?"

---

## Yes — Debezium Captures Everything, But You Must Parse the Envelope and Use MERGE INTO

Debezium captures **every change** — INSERTs, UPDATEs, and DELETEs — not just new rows. That's the good news. The tricky part is that Debezium publishes these changes in a structured JSON format called the **Debezium envelope**, and you must parse that envelope correctly before writing to Iceberg. Straight append-only writes will turn every UPDATE into a duplicate row and ignore every DELETE entirely. The correct pattern uses Spark Structured Streaming with `foreachBatch` and Iceberg's `MERGE INTO` to apply changes by primary key.

---

## What Debezium Actually Produces: The Event Envelope

When Debezium reads your Postgres write-ahead log (WAL), it converts every row change into a JSON event published to Kafka. That JSON has a specific structure:

```json
{
  "op": "u",
  "before": {
    "user_id": "alice",
    "plan": "free",
    "email": "alice@example.com",
    "updated_at": 1716259200000000
  },
  "after": {
    "user_id": "alice",
    "plan": "pro",
    "email": "alice@example.com",
    "updated_at": 1716259260000000
  },
  "source": { "db": "app_db", "table": "users", ... },
  "ts_ms": 1716259261000
}
```

The critical field is **`op`** — the operation type:

| `op` value | Meaning | `before` | `after` |
|---|---|---|---|
| `c` | INSERT (Create) | null | Full new row |
| `u` | UPDATE | Old row values | New row values |
| `d` | DELETE | Old row values | null |
| `r` | Snapshot read | null | Full row |

**Debezium captures UPDATEs and DELETEs, not just INSERTs.** This is the critical difference from a nightly batch job that only sees "new or changed rows since yesterday." Debezium sees the exact operation that happened, including the full before/after state.

For your "free to pro" plan upgrade, the event will have `op='u'`, `before.plan='free'`, `after.plan='pro'` — the complete picture of what changed.

---

## The Critical Mistake: Why Append-Only Fails

A naive first attempt reads from Kafka and writes directly to Iceberg:

```python
spark.readStream \
    .format("kafka") \
    .option("subscribe", "postgres.public.users") \
    .load() \
    .writeStream \
    .format("iceberg") \
    .option("path", "s3a://lakehouse/analytics/users") \
    .start()
```

**This produces garbage data.** Three specific problems:

1. **Raw bytes, not real columns.** The Iceberg table ends up with columns like `key` (bytes), `value` (bytes), `topic`, `partition`, `offset` — none of your actual user columns (`user_id`, `plan`, `email`).
2. **Every event appends a new row.** When the plan UPDATE event arrives, it appends a new row instead of updating the existing one. Now you have two rows for alice: one with `plan='free'` and one with `plan='pro'`. All aggregations are wrong.
3. **Deletes add rows instead of removing them.** When a user deletes their account, Debezium sends `op='d'`. Your append job inserts it as a new row. The deleted user keeps appearing in all your queries.

---

## The Correct Pattern: Parse the Envelope, Apply MERGE INTO

The working approach has three steps: parse the JSON, separate by operation type, apply `MERGE INTO` per micro-batch.

```python
from pyspark.sql.functions import col, from_json
from pyspark.sql.types import StructType, StructField, StringType, LongType

# Schema of the Postgres table's row (the "after" image)
row_schema = StructType([
    StructField("user_id",    StringType()),
    StructField("plan",       StringType()),
    StructField("email",      StringType()),
    StructField("updated_at", LongType()),   # Debezium encodes timestamps as epoch microseconds
])

def process_batch(batch_df, batch_id):
    if batch_df.isEmpty():
        return

    # Step 1: Parse the Debezium envelope from the raw Kafka value bytes
    parsed = batch_df.select(
        from_json(
            col("value").cast("string"),
            StructType([
                StructField("op",     StringType()),
                StructField("before", row_schema),
                StructField("after",  row_schema),
            ])
        ).alias("e")
    ).select("e.*")

    # Step 2: UPSERTs — INSERT, UPDATE, and snapshot reads all use the "after" image
    upserts = parsed.filter(col("op").isin("c", "u", "r")).select("after.*")
    if not upserts.isEmpty():
        upserts.createOrReplaceTempView("cdc_upserts")
        spark.sql("""
            MERGE INTO iceberg.analytics.users t
            USING cdc_upserts s ON t.user_id = s.user_id
            WHEN MATCHED THEN UPDATE SET *
            WHEN NOT MATCHED THEN INSERT *
        """)

    # Step 3: DELETEs — use the "before" image to identify which row to remove
    deletes = parsed.filter(col("op") == "d").select("before.user_id")
    if not deletes.isEmpty():
        deletes.createOrReplaceTempView("cdc_deletes")
        spark.sql("""
            MERGE INTO iceberg.analytics.users t
            USING cdc_deletes s ON t.user_id = s.user_id
            WHEN MATCHED THEN DELETE
        """)

# Stream configuration
spark.readStream \
    .format("kafka") \
    .option("kafka.bootstrap.servers", "kafka-broker-1:9092,kafka-broker-2:9092") \
    .option("subscribe", "postgres.public.users") \
    .option("startingOffsets", "latest") \
    .load() \
    .writeStream \
    .foreachBatch(process_batch) \
    .option("checkpointLocation", "s3a://lakehouse/streaming-checkpoints/users") \
    .trigger(processingTime="60 seconds") \           # minimum 60s — below this creates too many small files
    .start() \
    .awaitTermination()
```

**Why `foreachBatch` is required:** Iceberg's streaming sink (`.format("iceberg")`) only supports append mode. To run arbitrary SQL like `MERGE INTO`, you need `foreachBatch`, which hands you each micro-batch as a regular DataFrame that you can manipulate with any Spark SQL.

---

## Tracing the Plan Change Through the Pipeline

Here's your exact "free to pro" scenario, step by step:

1. **In Postgres:** `UPDATE users SET plan='pro', updated_at=NOW() WHERE user_id='alice'` commits.
2. **Debezium reads the WAL** and publishes to Kafka: `op='u'`, `before.plan='free'`, `after.plan='pro'`.
3. **Spark micro-batch fires** (within 60 seconds of the commit).
4. **`process_batch` runs:** Parses the envelope, sees `op='u'`, extracts `after` → `(user_id='alice', plan='pro', ...)`.
5. **MERGE INTO fires:**
   ```sql
   MERGE INTO iceberg.analytics.users t
   USING cdc_upserts s ON t.user_id = s.user_id   -- finds alice's existing row
   WHEN MATCHED THEN UPDATE SET *                   -- updates plan to 'pro'
   ```
6. **Iceberg writes a new snapshot.** The previous row is overwritten (CoW by default in Iceberg 1.5.2); the new snapshot references the updated file.
7. **Concurrent queries** running during the commit see a consistent view — either the old `plan='free'` state or the new `plan='pro'` state, never a mix. This is Iceberg's ACID guarantee.

**Yes — Iceberg supports updating individual rows.** The mechanism is `MERGE INTO`, which matches on a join key (here `user_id`) and updates all columns to the new values. It does not require rewriting the entire table.

---

## Prerequisites: What Debezium Needs from Postgres

Before wiring Debezium to publish to a Kafka topic for Iceberg ingestion, verify these Postgres-side requirements. If Debezium has been running for six months against a replica, most of these are already done — but confirm them:

1. `wal_level = logical` in `postgresql.conf` (requires a Postgres restart).
2. A publication: `CREATE PUBLICATION debezium_pub FOR TABLE users;`
3. A replication slot: `SELECT pg_create_logical_replication_slot('debezium_slot', 'pgoutput');`
4. Debezium database user with the `REPLICATION` role attribute (a role attribute, not a regular GRANT).
5. A `pg_hba.conf` entry allowing replication connections from the Debezium host.
6. The Debezium connector configured with `"plugin.name": "pgoutput"` and the slot name above.

If you were replicating to a second Postgres, Debezium was already reading from the primary's WAL. You can add a new connector configuration pointing to the same Kafka cluster with a different topic name for the Iceberg-bound stream — your existing replication setup is unaffected.

---

## Schema Evolution: What Happens When You Add a Column

When you add a column to the Postgres `users` table, Debezium automatically picks it up in subsequent events — the new column appears in the `after` JSON. But your Iceberg table doesn't know about it yet, and the `from_json` schema in your Spark job doesn't include it either.

The safest approach:
1. Pause the Spark streaming job (graceful shutdown via `query.stop()`).
2. Add the column to Iceberg: `ALTER TABLE iceberg.analytics.users ADD COLUMN new_col VARCHAR;`
3. Update the `row_schema` in your Spark job to include the new field.
4. Restart the job. It resumes from the checkpoint — no events are lost.

Do not try to add the column while the streaming job is running. The schema mismatch will cause the `from_json` call to silently drop the new column until you redeploy.

---

## Should You Actually Switch to Streaming?

Before committing to this, ask: **does your analytics actually need sub-hourly freshness?** The nightly batch job you already have is much simpler to operate:

| | Streaming (Debezium + Kafka) | Nightly batch |
|---|---|---|
| Data freshness | < 1 minute | Next morning |
| Infrastructure complexity | High (Kafka, Debezium, stream checkpoints) | Low |
| Debugging difficulty | High (streaming failures are subtle) | Low (Spark logs) |
| Schema evolution | Manual pause-alter-resume | Handled at job start |
| File accumulation | Needs nightly compaction | Controlled naturally |

Move to streaming only when a business requirement actually demands it — real-time fraud detection, live in-app usage counters, alerts that fire within minutes. For "our dashboards show last night's data," the nightly batch job is the right call.

---

## Key Takeaways

1. **Debezium emits INSERTs, UPDATEs, and DELETEs** via the `op`, `before`, and `after` fields in the event envelope — not just new rows.
2. **Never write Debezium events to Iceberg with append mode.** Parse the envelope, separate by operation type, and apply MERGE INTO per micro-batch.
3. **Iceberg supports row-level updates via MERGE INTO.** It matches on a primary key and updates the matched rows atomically.
4. **Use `foreachBatch` in Spark Structured Streaming** to run MERGE INTO SQL — the native Iceberg sink only supports append.
5. **Set trigger interval to 60 seconds minimum.** Sub-minute triggers create too many small Parquet files and degrade query performance without meaningful freshness gains.
6. **Add nightly compaction** alongside the streaming job: `CALL iceberg.system.rewrite_data_files(...)` — MERGE INTO produces small files that accumulate quickly.
