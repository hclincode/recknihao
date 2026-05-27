# Iter144 Q2 — Answer

**Question**: "We're using Debezium to stream changes from Postgres into our lakehouse, and a customer just complained their dashboard was showing data from three hours ago. I had no idea we were that far behind — I didn't even know there was a way to measure how delayed the pipeline is. How do I tell if Debezium is falling behind in real time, what causes it to slow down like that, and how should I set up some kind of alert before customers notice it before we do?"

---

## The Three Layers Where Lag Accumulates

When a change happens in Postgres, it must travel through three separate systems before it appears in your Iceberg table:

1. **Debezium source lag** — how far behind is Debezium reading from Postgres's WAL (Write-Ahead Log)?
2. **Kafka consumer lag** — how many events are sitting in the Kafka topic waiting to be processed?
3. **Spark micro-batch lag** — how fast is your Spark Structured Streaming job applying those events to Iceberg?

Each one can independently slow things down. A 3-hour delay usually means at least two of these are backed up.

---

## Layer 1: Measuring Debezium Lag via the Replication Slot

Debezium's progress is tracked by a **replication slot** in Postgres — a bookmark Postgres maintains to know "what WAL has Debezium already read?" The key metric is `confirmed_flush_lsn` (Log Sequence Number).

**Query to measure Debezium's current lag:**

```sql
SELECT
    slot_name,
    active,
    confirmed_flush_lsn,
    pg_current_wal_lsn()                                        AS current_wal_lsn,
    pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)  AS lag_bytes,
    ROUND(
        pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)
        / 1024.0 / 1024.0 / 1024.0, 2
    )                                                           AS lag_gb
FROM pg_replication_slots
WHERE slot_name = 'debezium_slot';
```

Run this every 2 minutes from your monitoring system. Key fields:
- **`lag_bytes` / `lag_gb`** — how far behind Debezium is reading. If this is growing, something in the chain is slow.
- **`active`** — is Debezium currently connected? `false` means Debezium has disconnected and WAL is piling up with no consumer. This is critical.

In your case with a 3-hour delay, expect to see `lag_gb` in the range of 5–50+ GB depending on your Postgres write rate.

**Alert thresholds:**
- **Warning: `lag_bytes > 50 GB`** — investigate within the hour.
- **Critical: `lag_bytes > 150 GB`** — page on-call immediately; you're approaching WAL disk exhaustion on the Postgres primary.
- **Critical: `active = false` for > 5 minutes** — page immediately; WAL is accumulating with nothing consuming it and the slot will hold WAL indefinitely.

---

## What Causes Debezium to Fall Behind

1. **Large transactions in Postgres** — a bulk `INSERT` or `UPDATE` affecting millions of rows. Debezium must read and emit the entire transaction's events before moving to the next one. A large data migration or import causes severe lag.

2. **High WAL volume from application traffic** — a write spike (bulk import, data sync, bug causing excessive writes) generates WAL faster than Debezium can drain it.

3. **Kafka is not accepting events fast enough** — if Kafka is full or slow, Debezium stalls waiting to produce events and cannot read more WAL.

4. **Debezium pod is down** — if the pod crashed, the slot remains active in Postgres but nothing is consuming WAL. The slot holds all WAL since the crash, and catch-up starts from scratch when Debezium restarts.

5. **`REPLICA IDENTITY FULL` overhead** — tables with `REPLICA IDENTITY FULL` (needed for full `before` images) double WAL volume for UPDATE/DELETE operations.

---

## Layer 2: Measuring Kafka Consumer Lag

After Debezium publishes to Kafka, your Spark job consumes from a consumer group — creating a second lag point.

**Check from the command line:**

```bash
kafka-consumer-groups.sh \
  --bootstrap-server kafka:9092 \
  --group your-spark-consumer-group-name \
  --describe
```

Output:
```
TOPIC                     PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG
postgres.public.events    0          12345           12500           155
```

The **LAG** column is the number of unconsumed messages per partition.

**To measure lag in time:** each Debezium event contains a `ts_ms` field — the timestamp (in milliseconds) when Postgres committed the change. Compare this to current time:

```python
# In your Spark streaming job's foreachBatch
from pyspark.sql.functions import current_timestamp, col

def process_batch(batch_df, batch_id):
    max_age_s = batch_df.select(
        (current_timestamp().cast("long") - col("envelope.ts_ms") / 1000).alias("age_s")
    ).agg({"age_s": "max"}).collect()[0][0]
    print(f"Batch {batch_id}: max event age {max_age_s:.0f}s")
```

If events have `ts_ms` values from 3 hours ago, Kafka + Spark lag together are your problem.

**Alert thresholds:**
- **Warning: max message age > 1 hour** — investigate Spark throughput.
- **Critical: max message age > 3 hours** — Spark is far behind.

---

## Layer 3: Spark Micro-Batch Lag

Your Spark job reads Kafka in micro-batches and writes to Iceberg via `MERGE INTO`. This is almost always the slowest layer because `MERGE INTO` with Copy-on-Write (CoW) — Iceberg 1.5.2's default — rewrites entire Parquet files for each affected row.

**Check Spark logs:**
```bash
kubectl logs -f <spark-driver-pod> | grep -i "batch\|duration\|merge"
```

If each `MERGE INTO` takes 30+ seconds and your trigger is every 60 seconds, you're already queuing. New batches arrive faster than old ones finish.

**To speed up Spark for high-frequency CDC tables**, switch to Merge-on-Read (MoR):

```sql
-- Spark SQL only — sets write mode on the table
ALTER TABLE iceberg.analytics.events SET TBLPROPERTIES (
  'write.delete.mode' = 'merge-on-read',
  'write.update.mode' = 'merge-on-read',
  'write.merge.mode'  = 'merge-on-read'
);
```

MoR writes delete files instead of rewriting Parquet files, dramatically reducing write latency. Trade-off: reads become slightly slower until you run compaction. This is the right trade-off when catching up from a large lag.

---

## The 3-Hour Delay: Diagnostic Checklist

When the customer complained, this is the 3-step diagnosis:

```bash
# Step 1: Debezium slot lag
psql -h postgres -c "
  SELECT lag_gb FROM (
    SELECT ROUND(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)/1073741824.0, 2) AS lag_gb
    FROM pg_replication_slots WHERE slot_name = 'debezium_slot'
  ) t;"

# Step 2: Kafka consumer lag
kafka-consumer-groups.sh --bootstrap-server kafka:9092 --group <spark-group> --describe | grep LAG

# Step 3: Spark logs
kubectl logs <spark-driver-pod> | tail -50 | grep batch
```

One (or more) of these will show the culprit. Fix it before trying to catch up.

---

## How to Catch Up Safely When 3 Hours Behind

**Do NOT skip events.** Do not reset consumer group offsets, delete Kafka messages, or truncate tables to "skip ahead" — this creates silent data gaps with no error.

1. **Identify the bottleneck** — use the diagnostic checklist. Fix the root cause first.

2. **Do not restart Debezium** just to "reset" it. Depending on `snapshot.mode`, a restart can trigger a full re-snapshot, adding massive additional load. Only restart if Debezium is completely stuck (not consuming any WAL for > 30 minutes).

3. **Speed up Spark** if MERGE INTO is the bottleneck:
   - Switch to MoR mode (above)
   - Increase trigger interval (`processingTime="120 seconds"`) to batch more events per commit
   - Check executor memory — OOM failures cause retries that compound lag

4. **Let the pipeline catch up naturally.** A 3-hour lag on a healthy pipeline typically self-corrects within 1–4 hours. Your customer's dashboard will backfill automatically as events arrive.

5. **Monitor the catch-up** every 5 minutes:
   ```bash
   while true; do
     echo "=== $(date) ==="
     psql -h postgres -c "SELECT lag_gb FROM pg_replication_slots WHERE slot_name='debezium_slot';" | tail -2
     kafka-consumer-groups.sh --bootstrap-server kafka:9092 --group <group> --describe | grep "LAG"
     sleep 300
   done
   ```

When `lag_gb` stops growing and starts shrinking, you are catching up.

---

## Setting Up Alerts Before Customers Notice

Wire these into Prometheus / AlertManager:

```yaml
groups:
  - name: cdc_lag
    rules:
      - alert: DebeziumSlotLagHigh
        expr: debezium_slot_lag_bytes > 53687091200   # 50 GB
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Debezium {{ $value | humanize1024 }}B behind"

      - alert: DebeziumSlotInactive
        expr: debezium_slot_active == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Debezium slot inactive — WAL accumulating with no consumer"

      - alert: KafkaConsumerLagHigh
        expr: kafka_consumer_lag_sum > 100000
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Spark {{ $value }} messages behind in Kafka"

      - alert: CDCEventAgeHigh
        expr: spark_streaming_max_event_age_seconds > 3600   # 1 hour
        for: 10m
        labels:
          severity: critical
        annotations:
          summary: "CDC events are {{ $value | humanizeDuration }} old"
```

Push the Postgres slot lag metric from a cronjob or from a Postgres exporter. For Kafka, use the Kafka exporter or Strimzi's built-in metrics. For Spark event age, instrument your `foreachBatch` function to push to Prometheus Pushgateway.

---

## Key Prevention Points

1. **Monitor all three lag layers now**, not after the next customer complaint.
2. **The replication slot is the most important metric** — if it fills (WAL disk full), Postgres can go read-only. Alert at 50 GB, page at 150 GB.
3. **High-frequency CDC tables should use MoR mode** from day one, not after an incident.
4. **Surface lag to users** — display "data as of [timestamp]" on dashboards based on `max(ingested_at)` so users know freshness without filing a support ticket.
