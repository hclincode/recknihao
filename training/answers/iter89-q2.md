# Iter89 Q2 — Answer

**Question**: Debezium is set up but worried about what happens if it falls behind or crashes. Does Postgres really hold onto its transaction log until Debezium catches up? How do we monitor the backlog?

---

## Answer

## Yes, the disk-fill risk is real

You're asking exactly the right question. The risk is real, and Postgres does hold onto WAL (Write-Ahead Log) segments indefinitely until Debezium confirms it has processed them. If Debezium crashes, gets stuck, or falls behind, those WAL segments pile up on disk and can eventually fill your storage.

**The core mechanism:** When you create a logical replication slot in Postgres (which Debezium requires), Postgres uses that slot as a bookmark for "up to which point in the WAL has Debezium read?" Postgres holds onto every WAL segment that hasn't been confirmed as read yet. If Debezium is not making progress, that bookmark doesn't advance, and Postgres can't discard old segments — they accumulate indefinitely.

## How to check the backlog right now

Run this query on your Postgres primary to see the current state of your replication slot:

```sql
SELECT slot_name, slot_type, active, restart_lsn, confirmed_flush_lsn
FROM pg_replication_slots
WHERE slot_name = 'debezium_slot';
```

**What the columns mean:**

- `active` — should be `true` if Debezium is actively streaming. If `false`, Debezium is disconnected, and WAL will accumulate.
- `restart_lsn` — the earliest point in the WAL that Postgres must keep. Everything before this can be discarded.
- `confirmed_flush_lsn` — the point Debezium has confirmed it has processed. If this stays frozen while new data arrives, Debezium is stuck.

**The key warning sign:** If `confirmed_flush_lsn` hasn't advanced in the last hour, Debezium is either crashed or severely backlogged.

## Monitoring the lag — what to alert on

To understand how far behind Debezium actually is, compare the confirmed flush LSN to the current write position:

```sql
SELECT 
    slot_name,
    confirmed_flush_lsn,
    pg_current_wal_lsn() AS current_wal_position,
    pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS bytes_behind
FROM pg_replication_slots
WHERE slot_name = 'debezium_slot';
```

This tells you how many bytes of WAL Debezium hasn't yet processed. The larger this number, the closer you are to running out of disk.

## Calculate your safety margin

```sql
SELECT 
    slot_name,
    pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS bytes_behind,
    ROUND(
        pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) / 1024.0 / 1024.0
    ) AS mb_behind
FROM pg_replication_slots
WHERE slot_name = 'debezium_slot';
```

**Set up an alert based on your disk space and write rate.** For example:
- If your Postgres primary generates 10 GB of WAL per hour and you have 100 GB of free disk, you have roughly 10 hours before the disk fills.
- Alert when `bytes_behind` exceeds 50% of your safe capacity (yellow warning).
- Page on-call when `bytes_behind` exceeds 80% (red alert).

Also alert immediately if `active = false` for more than 5 minutes — that means Debezium is disconnected.

## If Debezium falls behind — immediate actions

**Check if Debezium is actually running:**

If `active = false`, Debezium is disconnected. Check its logs:

```bash
kubectl logs -l app=debezium-connector --tail=100
```

**If Debezium crashed and left the slot but isn't advancing:**

Do NOT delete the slot immediately — if you do, Postgres will discard WAL that Debezium hasn't yet processed and you'll silently lose data. Instead:

1. Check Debezium's logs for the error.
2. Fix the error (disk space, Kafka broker connectivity, etc.).
3. Restart Debezium — it will resume from where it left off.

**As a last resort (data loss risk):**

If the disk is about to fill and restarting Debezium won't work in time, you can drop and recreate the slot — but this **will cause data loss** for any rows changed while Debezium wasn't running:

```sql
SELECT pg_drop_replication_slot('debezium_slot');
SELECT pg_create_logical_replication_slot('debezium_slot', 'pgoutput');
```

You'll need a separate backfill job to re-sync skipped rows. Avoid this path if at all possible.

## Recommended monitoring setup

Set up a scheduled query (hourly) that runs the `bytes_behind` query above and sends the result to your monitoring system:

| Alert level | Condition | Action |
|---|---|---|
| Warning | `bytes_behind > 50 GB` (or 50% of safe capacity) | Investigate Debezium health |
| Critical | `bytes_behind > 150 GB` (or 80% of safe capacity) | Page on-call immediately |
| Critical | `active = false` for > 5 min | Page on-call immediately |

## Summary

The disk-fill risk is real. Postgres holds WAL for as long as the replication slot hasn't confirmed processing. Monitor with `pg_replication_slots` — specifically `confirmed_flush_lsn` vs `pg_current_wal_lsn()` — and alert when the gap gets large. If Debezium falls behind, restart it first (it'll catch up from where it left off). Only drop the slot as a last resort, as it causes data loss.
