# Answer to Q1: Postgres Replication Slot WAL Bloat — Debezium CDC (Iter 316)

You've discovered what ops teams call **the #1 Debezium production incident.** This is not a rare edge case — every Debezium deployment will eventually hit some version of this. Here's what's happening and how to fix it without turning off your pipeline.

## What is a replication slot?

When Debezium streams changes from Postgres, it needs a way to tell Postgres "I've read up to position X in your write-ahead log (WAL)." The WAL is Postgres's internal change journal — every insert, update, and delete that commits gets written there. Normally, Postgres discards old WAL segments once they're no longer needed.

A **logical replication slot** is Postgres's bookmark that says "this consumer (Debezium) is reading the WAL, so keep all segments from position X forward." Without a slot, Postgres would delete WAL segments before Debezium could read them.

## Why your disk is filling up

Three-part failure chain:

1. **Debezium uses the slot to tell Postgres where it's read to.** Every time Debezium successfully processes a batch of changes, it advances the slot's `confirmed_flush_lsn` (confirmed flushed log sequence number). Postgres only then considers that WAL segment safe to delete.

2. **If Debezium falls behind, the slot stops advancing.** A connector crash, network split between your Kubernetes pod and Postgres, Kafka becoming unavailable, or a Spark job stuck on a bad record — all freeze the slot's `confirmed_flush_lsn` at some old position.

3. **Postgres holds ALL WAL segments from that frozen position onward.** New writes to the database continue generating new WAL segments. If Debezium stays down for days, those segments accumulate faster than your application can delete them. When disk hits 100%, Postgres goes read-only or crashes — killing your production application database.

This is why the disk fills on the **production database side**, not the analytics side. The slot prevents Postgres from cleaning up its own WAL.

## The three non-negotiable safeguards

Implement all three. Think of them as defense layers.

### 1. Set `max_slot_wal_keep_size` in Postgres config (Postgres 13+)

This is the database's self-defense mechanism. Add to `postgresql.conf`:

```
max_slot_wal_keep_size = 50GB
```

If the replication slot falls more than 50 GB behind the current WAL position, Postgres **auto-invalidates the slot** (marks it `wal_status = 'lost'`). This kills the CDC pipeline — Debezium errors out — but prevents the disk from filling up and taking down your production database.

"CDC dies, application stays up" is almost always the right tradeoff.

### 2. Monitor the slot's lag continuously

Query this every 30 seconds (Prometheus + postgres_exporter, or a Kubernetes CronJob):

```sql
SELECT
  slot_name,
  active,
  wal_status,
  safe_wal_size,
  pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS bytes_behind_slot,
  pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS bytes_behind_consumer
FROM pg_replication_slots
WHERE slot_name = 'debezium_slot';
```

**Two LSN columns matter for different reasons:**
- `restart_lsn` — the position Postgres must keep WAL from; this drives disk usage. Slot is invalidated when WAL before `restart_lsn` would be deleted.
- `confirmed_flush_lsn` — what Debezium has confirmed processing; this is the consumer's acknowledgement lag.

**`safe_wal_size`** (Postgres 13+) directly tells you how much more WAL can be written before the slot gets invalidated — the most actionable single metric.

**Alert thresholds:**
- `active = false` for >5 minutes → page immediately (Debezium disconnected)
- `bytes_behind_consumer > 50 GB` → warn
- `bytes_behind_consumer > 150 GB` → page on-call (approaching invalidation)
- `wal_status IN ('unreserved', 'lost')` → page on-call (slot at risk or already gone)

**`inactive_since`** (Postgres 14+) shows when the slot last had an active consumer — useful for spotting silent disconnects.

### 3. Have a recovery runbook before you need it

When a slot gets invalidated (`wal_status = 'lost'`), walk through this once in staging so your on-call engineer doesn't learn it at 3 AM:

```sql
-- 1. Drop the invalid slot
SELECT pg_drop_replication_slot('debezium_slot');

-- 2. Recreate at current WAL position
SELECT pg_create_logical_replication_slot('debezium_slot', 'pgoutput');
```

3. Restart Debezium with `snapshot.mode: no_data` — tells it to skip re-snapshotting all rows and just stream changes from now.
4. Run a targeted backfill from Postgres for the gap window (the time between slot invalidation and Debezium restart).

## One additional guard: heartbeats

If you have low-traffic tables, the slot can fall behind just from idleness — no Debezium failure needed. Add to your Debezium connector config:

```
heartbeat.interval.ms = 30000
```

This makes Debezium insert a heartbeat event every 30 seconds, which flows through the WAL and advances the slot's position even if no real application data changed.

## Summary: your action items

1. Add `max_slot_wal_keep_size = 50GB` to `postgresql.conf` and coordinate with Ops for a restart.
2. Wire the `pg_replication_slots` monitoring query into your observability stack with the thresholds above.
3. Write a slot recovery runbook and have on-call walk through it once in staging.
4. Add `heartbeat.interval.ms = 30000` to the Debezium connector config.

Once all three are in place, a Debezium outage triggers an alarm for you to fix, rather than silently taking your production database offline.
