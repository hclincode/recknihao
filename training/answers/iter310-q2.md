# Answer to Q2: Postgres CDC Replication Slot WAL Bloat (Iter 310)

## Understanding Replication Slots and the Disk-Fill Outage

A **replication slot** is Postgres's bookmark system. Think of it as a post-it note that says "Debezium has confirmed reading everything up to this point in the transaction log — you can delete older data." Without it, Postgres doesn't know whether Debezium has actually consumed the changes, so it must hold onto every write-ahead log (WAL) segment forever just in case.

Here's the catastrophic scenario:

**What a replication slot does:** When Debezium starts, it creates a logical replication slot in Postgres. As Debezium reads events from the transaction log and writes them into Iceberg via Spark, it tells Postgres "I've confirmed through LSN X" (LSN is the Log Sequence Number — a byte position in the transaction log). Postgres then knows it can delete WAL segments older than that point. The slot's `confirmed_flush_lsn` field tracks this position.

**When the disk fills up:** If Debezium falls behind — the connector crashes, Kafka becomes unavailable, your Spark sink hangs, or a poison message gets Debezium stuck — the slot's confirmed position stops advancing. Postgres doesn't know Debezium will ever resume, so it keeps every single WAL segment from that slot forward, **forever**. On a write-heavy Postgres instance (typical for a SaaS app), WAL can grow at gigabytes per hour. Within hours or a day, your 500 GB data disk can fill completely.

**Why this is a production catastrophe:** When the Postgres data disk fills, the primary database goes **read-only or crashes entirely**. Your application cannot write to the database anymore. The analytics CDC pipeline — not an app bug, not a user-facing issue — has taken down the production application database.

This is the #1 production failure mode for Debezium deployments. Teams that haven't pre-built monitoring and recovery runbooks will discover this as a P0 page that brings down the entire application.

## Three Non-Negotiable Protections

Wire all three of these **before** you turn on Debezium in production.

### 1. Monitor Slot Lag Relentlessly

Run this query regularly (every minute in production) against the Postgres primary:

```sql
SELECT slot_name, active, wal_status,
       pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS bytes_behind
FROM pg_replication_slots
WHERE slot_name = 'debezium_slot';
```

Set up alerts:
- **Warning** when `bytes_behind > 50 GB`. This means Postgres is retaining 50 GB of WAL for Debezium. Investigate.
- **Critical page** when `bytes_behind > 150 GB` or when it exceeds 80% of your safe disk capacity — whichever is smaller.
- **Critical page** when `active = false` for more than 5 minutes. This means Debezium has disconnected and isn't consuming at all.

The `wal_status` column (Postgres 13+) tells you the health:
- `reserved` — Postgres is holding WAL safely for the slot.
- `lost` — catastrophe: Postgres has already deleted the WAL this slot needed. See recovery procedure below.

### 2. Set `max_slot_wal_keep_size` in postgresql.conf

This is Postgres's self-defense mechanism. It says: "If any slot falls more than 50 GB behind, auto-invalidate it rather than letting the disk fill and crashing the database."

```
max_slot_wal_keep_size = 50GB   # in postgresql.conf
```

When a slot hits this limit, Postgres **auto-invalidates** it (sets `wal_status = 'lost'`), freeing the WAL segments. Your CDC pipeline will fail to resume, but **your application database stays alive**. This is exactly the tradeoff you want: "lose CDC briefly, keep the app running" beats "CDC was fine for a few hours, then the app went down."

### 3. Have a Recovery Runbook Before You Need It

When a slot becomes invalid (`wal_status = 'lost'`), follow this four-step procedure. **Walk through it once on a staging environment first** so the on-call engineer has muscle memory:

**Step 1: Drop the invalid slot in Postgres**
```sql
-- Run on the Postgres primary
SELECT pg_drop_replication_slot('debezium_slot');
```

**Step 2: Recreate the slot at the current position**
```sql
SELECT pg_create_logical_replication_slot('debezium_slot', 'pgoutput');
```

**Step 3: Restart Debezium with `snapshot.mode: never`**

Update the Debezium connector configuration to:
```json
{
  "snapshot.mode": "never"
}
```

Then restart the connector. It will start streaming WAL from the new slot's position, skipping any snapshot. This is fast because you're not re-reading billions of rows.

**Step 4: Backfill the gap via MERGE INTO from Postgres**

There is now a window of lost changes — the rows that were modified between when the slot became invalid and when Debezium restarted. Use a targeted MERGE INTO from the Postgres primary to patch the gap in Iceberg:

```sql
-- Run a Spark job to MERGE rows from Postgres PRIMARY 
-- (not the replica) for the lost time window.
-- The MERGE INTO idempotently updates Iceberg to match Postgres
-- for any row modified during the invalidation window.
MERGE INTO iceberg_events t
USING postgres_events s
ON t.id = s.id
WHEN MATCHED THEN UPDATE SET *
WHEN NOT MATCHED THEN INSERT *
WHERE s.updated_at BETWEEN :start_time AND :end_time;
```

The key: use the Postgres **primary** for this read, not a replica, so you get consistent data without replication lag complications.

## Additional Production Safeguard: Heartbeat Events

On tables with low write volume, the slot can fall behind simply because there's nothing to read. Configure Debezium to emit heartbeat events every 30 seconds:

```json
{
  "heartbeat.interval.ms": 30000,
  "heartbeat.action.query": "INSERT INTO debezium_heartbeat (slot_name) VALUES ('debezium_slot')"
}
```

This keeps the slot's confirmed position advancing even on idle tables, so you don't accidentally trigger `max_slot_wal_keep_size` auto-invalidation from pure silence.

## Summary: What to Do Monday Morning

1. Set `max_slot_wal_keep_size = 50GB` in postgresql.conf and reload.
2. Add monitoring on `pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)` with warn at 50 GB, critical at 150 GB.
3. Add monitoring on `active = false` for more than 5 minutes.
4. Write the four-step recovery procedure into your runbook and run it once on staging with your on-call team.
5. When you deploy the Debezium connector, add `heartbeat.interval.ms: 30000` to the config.

`max_slot_wal_keep_size` is the difference between "CDC pipeline goes down, app stays up" and "CDC pipeline takes the app down." These three mitigations together are what make Debezium safe to run in production.
