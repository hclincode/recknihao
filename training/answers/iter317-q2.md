# Answer to Q2: Debezium Heartbeat Not Reducing Replication Slot Lag on Low-Traffic Database (Iter 317)

Your heartbeat interval config is correct in principle, but it's missing two supporting pieces that are required for heartbeats to actually advance the Postgres replication slot. Here's why.

## What heartbeats actually do (and what they don't)

A heartbeat is a tiny database write that Debezium executes on a schedule (every 30 seconds with `heartbeat.interval.ms=30000`). That write commits to the PostgreSQL WAL — the same log Debezium is reading from. When Debezium reads and acknowledges that heartbeat event, it advances the replication slot's `confirmed_flush_lsn`, which tells Postgres "I'm still consuming; you can release old WAL segments."

**The key distinction:** `heartbeat.interval.ms` sends a heartbeat event through Kafka to advance Kafka consumer offsets. But to advance the **Postgres replication slot LSN** (the thing that prevents WAL accumulation), Debezium must write to a table on the **monitored Postgres database itself**. That's what `heartbeat.action.query` is for.

Without `heartbeat.action.query`, on a low-traffic database: Debezium generates heartbeat events in Kafka, Kafka offsets advance, the connector looks "healthy" — but the Postgres slot's `confirmed_flush_lsn` stays frozen because there's nothing new in the WAL for Debezium to acknowledge.

## Three pieces that must all work together

### 1. Create the heartbeat table on the monitored Postgres database

```sql
CREATE TABLE IF NOT EXISTS public.debezium_heartbeat (
  id INTEGER PRIMARY KEY DEFAULT 1,
  heartbeat_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT single_row CHECK (id = 1)
);

GRANT SELECT, INSERT, UPDATE ON public.debezium_heartbeat TO debezium_user;
```

The `CHECK (id = 1)` constraint is critical — it forces exactly one row forever. Without it, the table grows at ~2,880 rows/day (one per heartbeat) and eventually causes its own problems.

### 2. Add the heartbeat table to the Postgres publication

The publication is what Postgres logical decoding uses to decide which table changes to stream to Debezium. If the heartbeat table is **not in the publication**, Debezium writes the rows fine — but Postgres logical decoding filters them out. The replication slot never sees the heartbeat events and the `confirmed_flush_lsn` doesn't advance.

```sql
ALTER PUBLICATION debezium_pub ADD TABLE public.debezium_heartbeat;
```

**This is the most common missing piece.** The heartbeat is writing, the connector looks healthy, but the slot lag keeps growing because the heartbeat rows are invisible to logical decoding.

### 3. Configure `heartbeat.action.query` in the Debezium connector

Add both config properties to your connector:

```json
{
  "heartbeat.interval.ms": "30000",
  "heartbeat.action.query": "INSERT INTO public.debezium_heartbeat (id, heartbeat_at) VALUES (1, now()) ON CONFLICT (id) DO UPDATE SET heartbeat_at = now()"
}
```

The `ON CONFLICT ... DO UPDATE` pattern is the correct form — it upserts the single row, generating a WAL event each time that flows through logical decoding to Debezium.

## How to diagnose which piece is broken

Run these on your staging Postgres primary:

```sql
-- Check 1: Does the heartbeat table exist?
SELECT * FROM public.debezium_heartbeat;
-- Error = "relation does not exist" → create it (see above)

-- Check 2: Is the heartbeat table in the publication?
SELECT tablename FROM pg_publication_tables WHERE pubname = 'debezium_pub';
-- If public.debezium_heartbeat is missing → run ALTER PUBLICATION

-- Check 3: Is Debezium actually writing heartbeats?
-- Query the table, wait 30 seconds, query again
SELECT heartbeat_at FROM public.debezium_heartbeat;
-- If heartbeat_at isn't changing → heartbeat.action.query not configured or failing

-- Check 4: Is the slot advancing?
SELECT slot_name, confirmed_flush_lsn,
       pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS bytes_behind
FROM pg_replication_slots WHERE slot_name = 'your_slot_name';
-- If bytes_behind keeps growing after heartbeats are writing → publication issue
```

## Most likely cause for your setup

My guess: the heartbeat table exists and Debezium is writing to it (connector shows healthy), but the table isn't in the publication. Heartbeat rows are being written to Postgres but Postgres logical decoding is filtering them out — the slot's `confirmed_flush_lsn` never advances.

Run Check 2, add the table to the publication, restart the Debezium connector, and recheck the slot lag. The bytes_behind should start dropping within a few minutes.
