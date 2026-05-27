# Iter50 Q2 Answer — Debezium replication slot disk-bloat

**Question**: Spark Structured Streaming job died over a weekend; Postgres server ran out of disk space when WAL files accumulated in an unconsumed Debezium replication slot. What happened and how to prevent it?

---

## What happened (plain English)

Debezium uses a **replication slot** in Postgres — a bookmark that tracks which changes have been safely delivered to Kafka. As long as the slot is being consumed (Spark reads Kafka, which reads Debezium, which advances the slot), Postgres can safely discard old WAL files after the slot confirms it's done with them.

When your Spark job crashed over the weekend:
1. Debezium was still reading the Postgres WAL and sending events to Kafka
2. Kafka was storing the events (it kept them, waiting for Spark)
3. The replication slot stopped advancing — Spark wasn't consuming Kafka, so Debezium wasn't confirming to Postgres that WAL had been processed
4. Postgres kept every WAL file since the slot's last position, assuming "the consumer might still need these"
5. After 3 days of production write traffic, WAL accumulated until the disk filled

The replication slot is the mechanism that says "safe to delete old WAL files" — when the slot stops advancing, Postgres refuses to delete anything. This is by design: it guarantees no events are lost. The cost is unbounded disk growth when the consumer is down for an extended period.

## How to prevent this

**1. Monitor replication slot lag (most important)**

Query this in Postgres to see how much WAL is being retained per slot:

```sql
SELECT 
  slot_name,
  pg_size_pretty(
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
  ) AS retained_wal,
  active
FROM pg_replication_slots;
```

Set up an alert: if `retained_wal` exceeds 10 GB (or whatever fits your disk), page the on-call. On a busy production system, this gives you hours of warning before disk fills.

**2. Set `max_slot_wal_keep_size` (Postgres 13+)**

```sql
-- In postgresql.conf or via ALTER SYSTEM:
ALTER SYSTEM SET max_slot_wal_keep_size = '20GB';
SELECT pg_reload_conf();
```

This tells Postgres: "if a replication slot accumulates more than 20 GB of retained WAL, drop the slot rather than filling the disk." The database survives; the slot is lost (Debezium must resync from scratch). This is survivable — a Debezium resync takes hours, not days. A crashed Postgres database brings down production. The trade-off is clear.

**3. Supervise the Spark job with auto-restart**

A crashed streaming job should restart in minutes, not after a long weekend. On Kubernetes, run the Spark job as a Deployment (not a CronJob or a manual `spark-submit`) with a restart policy:

```yaml
spec:
  restartPolicy: Always
```

Or use an orchestrator (Airflow, Prefect) with automatic retries and alerting on failure. A job that dies silently over a weekend is an operational gap regardless of what the job does.

**4. Alert on Spark consumer lag**

Monitor the Kafka consumer group lag for your Debezium topic. If the consumer (Spark) is falling behind by more than your SLA (e.g., 30 minutes for a job that runs every 5 minutes), alert immediately — before the WAL grows large enough to matter.

## Recovery if the slot was dropped

If `max_slot_wal_keep_size` dropped the slot (or if you had to manually drop it to save the database), here's the recovery path:

1. Drop and recreate the Debezium replication slot via Debezium's connector management API
2. Do a full table snapshot of the Postgres source — Debezium's snapshot mode re-reads all rows from Postgres and writes them to Kafka
3. Resume streaming from the new slot position
4. Use `MERGE INTO` (not `append()`) in the Spark job so the snapshot re-write is idempotent in Iceberg

The snapshot can take hours for large tables. Plan for this when sizing `max_slot_wal_keep_size` — pick a value large enough to survive typical weekend outages without triggering a drop.

## The bigger lesson

CDC with Debezium is powerful but adds significant operational surface area — replication slots, Kafka consumer lag, exactly-once semantics, streaming job supervision. The production resources note that CDC adds ~3x more moving parts versus batch ingestion.

If your freshness requirement is hourly or daily (not sub-minute), consider whether simple batch ingestion (hourly Spark jobs reading from Postgres with a watermark) would serve your needs without the operational complexity of a live streaming pipeline.

CDC is worth the complexity when you need:
- Sub-hour data freshness for end-user-facing metrics
- Accurate capture of hard DELETEs (GDPR, audit trail)

For everything else, batch is simpler, cheaper, and more resilient to weekend incidents.
