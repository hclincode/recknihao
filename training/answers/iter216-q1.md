# Iter 216 Q1 — Postgres CDC to Iceberg: Implementation, Freshness, and Partial-Update Safety

## Answer

# CDC for Real-Time Postgres-to-Iceberg Sync: What You Need to Know

You're asking the right question at the right time. Your current copy-once-and-forget approach works for static reference data, but the moment you need sub-hourly freshness on mutable Postgres tables, you've outgrown batch ingestion. CDC (change data capture) is the path forward — but it's meaningfully more complex than the nightly Spark jobs you're running now.

## What CDC Requires on the Postgres Side

CDC requires six specific Postgres prerequisites on your **primary** database (CDC does not work from a read replica):

**1. `wal_level = logical` in postgresql.conf**
Your Postgres is probably set to `wal_level = replica` (the default). Debezium requires `logical`. This setting requires a **full Postgres restart**. The companion settings `max_wal_senders` and `max_replication_slots` (both default to 10 in Postgres 14+) also need to be verified.

**2. A Postgres publication**
```sql
CREATE PUBLICATION debezium_pub FOR TABLE customers, accounts;
```
Only tables in the publication emit change events.

**3. REPLICA IDENTITY FULL on tables where you need UPDATE/DELETE fidelity**
```sql
ALTER TABLE customers REPLICA IDENTITY FULL;
```
The cost is ~2x WAL volume for UPDATE-heavy tables.

**4. A logical replication slot**
```sql
SELECT pg_create_logical_replication_slot('debezium_slot', 'pgoutput');
```
Without a slot, Postgres discards WAL before Debezium reads it.

**5. A role with the REPLICATION attribute**
```sql
CREATE ROLE debezium_user WITH REPLICATION LOGIN PASSWORD 'strong_password';
GRANT SELECT ON ALL TABLES IN SCHEMA public TO debezium_user;
```
Missing the `REPLICATION` keyword is the #2 most common setup failure.

**6. A pg_hba.conf entry for replication connections**
```
host    replication     debezium_user    <connector_ip>/32    scram-sha-256
```
This is the #1 failure point. Regular SQL connection rules do NOT cover replication connections. After editing, reload: `SELECT pg_reload_conf();` (no restart needed).

## How Changes Actually Land in Iceberg

CDC is a three-tier pipeline:

**Tier 1: Debezium reads the WAL**
Debezium is a Kafka Connect plugin that tails your Postgres WAL and publishes row-change events to Kafka topics. Every INSERT, UPDATE, and DELETE becomes a message with: operation type (`op='i'`/`op='u'`/`op='d'`), new row values (`after` field), old row values (`before` field), and metadata (LSN, commit timestamp). Debezium requires no changes to your application code and doesn't affect write latency.

**Tier 2: Kafka buffers the events**
The Kafka topic is a persistent queue. If your downstream consumer is slow or crashes, events sit in Kafka (subject to retention, typically 7 days). This is why Kafka is a "decoupler."

**Tier 3: Spark Structured Streaming consumes and MERGE INTO Iceberg**
A long-running Spark job reads from Kafka in micro-batches (e.g., every 10 seconds) and applies changes to Iceberg via MERGE INTO:

```python
spark.readStream.format("kafka") \
  .option("kafka.bootstrap.servers", "kafka-bootstrap:9092") \
  .option("subscribe", "app-db.public.customers") \
  .load() \
  .select(from_json(col("value").cast("string"), schema).alias("cdc")) \
  .select("cdc.*") \
  .writeStream \
  .foreachBatch(merge_into_iceberg) \
  .start()
```

The `merge_into_iceberg` function:
```python
def merge_into_iceberg(df, batch_id):
  spark.sql("""
    MERGE INTO iceberg.analytics.customers t
    USING df s
    ON t.customer_id = s.customer_id
    WHEN MATCHED AND s.op = 'd' THEN DELETE
    WHEN MATCHED THEN UPDATE SET *
    WHEN NOT MATCHED THEN INSERT *
  """)
```

## Iceberg Snapshot Isolation — Can Trino See Partial Updates?

**No, Trino will never see a customer record halfway through an update.** Iceberg has strong ACID semantics — specifically, **snapshot isolation**:

- Each Iceberg write is atomic at the snapshot level. When Spark's MERGE INTO commits, it writes a new Iceberg snapshot.
- Trino queries always read from a single snapshot — the latest one at the time the query started.
- If a Trino query begins at 3:00:00 PM and a Spark MERGE commits at 3:00:05 PM, Trino's query continues reading the old snapshot and does not see the intermediate state.

In concrete terms: Spark applies a "customer 42 changed plan from Pro to Enterprise" event. A Trino query running simultaneously either sees the old version or the new version — never a mixed state. This is fundamentally different from reading directly from a Postgres replica during heavy writes.

## Practical Freshness You Can Achieve

**Near-real-time (5-30 minute lag)** — what most SaaS teams deploy:
- Debezium captures changes the moment they commit to Postgres.
- Spark micro-batches consume from Kafka every 10-30 seconds.
- A Postgres update at 3:00:00 PM is queryable in Trino by 3:00:15 PM.
- Operational cost: three moving parts (Debezium, Kafka, Spark Streaming), each with failure modes.

**Sub-minute freshness** requires tight tuning (1-second Spark micro-batches) but the bottleneck is Kafka consumer lag + Spark's batch window. The operational burden scales nonlinearly.

**Important caveat:** Even at sub-minute freshness, you're subject to Postgres commit latency, Kafka consumer-group lag, Spark batch-window duration, and Iceberg snapshot commit times. If you need "immediate" visibility, consider querying Postgres directly via Trino's PostgreSQL connector for hot data, and syncing only cold/historical data to Iceberg.

## The Bootstrap-to-CDC Handoff (Slot-First)

The safest handoff — do not pause application writes:

1. **Create the replication slot first** (retains WAL immediately):
   ```sql
   BEGIN;
   SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
   SELECT pg_create_logical_replication_slot('debezium_slot', 'pgoutput');
   SELECT pg_export_snapshot();  -- note the snapshot ID
   COMMIT;
   ```

2. **Bootstrap with Spark JDBC** using that snapshot for consistency — reads the point-in-time view while the primary is being written to.

3. **Start Debezium with `snapshot.mode: no_data`** — skips its own per-row snapshot (you've already loaded Iceberg) and begins streaming from the slot. WAL changes queued while Spark was running are replayed.

## What CDC Does NOT Solve

- Hard deletes that were committed before the slot was created are invisible to CDC.
- Network/Kafka failures still mean delayed freshness — CDC is "fresher than nightly batch," not "always fresh."
