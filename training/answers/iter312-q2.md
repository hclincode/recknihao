# Answer to Q2: pg_replication_slots — safe_wal_size and restart_lsn vs confirmed_flush_lsn (Iter 312)

Yes, `safe_wal_size` is real — and it's exactly the column you need to alert on. Here's what each metric means and which one to use.

## The Two LSN Columns: `restart_lsn` vs `confirmed_flush_lsn`

Think of a replication slot as Debezium's bookmark in Postgres's write-ahead log (WAL) — the record of every database change. The two LSN columns track different positions:

**`confirmed_flush_lsn`** — the position Debezium has **acknowledged consuming**. When your Spark consumer processes a change event and acknowledges it back through Kafka, Debezium confirms that position. This is the "consumer lag" metric — how far behind the latest committed transaction Debezium is.

**`restart_lsn`** — the **oldest WAL position the slot still needs to survive**. If Debezium crashes and restarts, it must re-read from `restart_lsn` onward to reconstruct any long-running transactions that were in-flight. This is the "slot survival" metric — it determines whether the slot is at risk of being invalidated.

The critical detail: **these two LSNs normally stay close, but they diverge during long-running transactions.** If a transaction is open in Postgres but hasn't committed yet, `confirmed_flush_lsn` keeps advancing for other committed changes, while `restart_lsn` stays pinned at that open transaction's start. If you measure slot pressure using `confirmed_flush_lsn`, you can underestimate the real risk by tens of gigabytes. A slot can be invalidated even while your `confirmed_flush_lsn` lag looks fine.

## The `safe_wal_size` Column — the Direct Headroom Metric

Yes, `safe_wal_size` (Postgres 13+) is Postgres telling you, in bytes, how much more WAL can be written before this slot is at risk. **No manual subtraction needed** — it's the direct answer to "how much headroom do we have left?"

Two important caveats:
- **If `safe_wal_size IS NULL`**: either the slot is already invalidated (`wal_status = 'lost'`), or `max_slot_wal_keep_size` is not set (default is `-1`, meaning unlimited). If unlimited, alert on `bytes_behind_restart` against your available disk space instead.
- **If `safe_wal_size` goes negative**: the slot has crossed the `max_slot_wal_keep_size` line but Postgres hasn't recycled the WAL yet. Treat this as critical — invalidation is imminent on the next checkpoint.

## The Monitoring Query

```sql
SELECT
    slot_name,
    active,
    wal_status,
    safe_wal_size,
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)        AS bytes_behind_restart,
    pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS bytes_behind_consumer,
    inactive_since,
    invalidation_reason
FROM pg_replication_slots
WHERE slot_name = 'debezium_slot';
```

Read the columns in this order:

1. **`safe_wal_size`** — primary headroom metric. Alert if below 50 GB (warning) or below 10 GB (critical).

2. **`bytes_behind_restart`** — slot-survival alerting. Postgres uses `restart_lsn` for slot invalidation decisions. Never use `confirmed_flush_lsn` for this — it gives false confidence.

3. **`bytes_behind_consumer`** — use for "is Debezium keeping up?" dashboards and SLOs, but **never for slot-invalidation alerts**.

4. **`wal_status`** — alert on `unreserved` (imminent risk) and `lost` (already invalidated, recovery required).

5. **`inactive_since`** (Postgres 14+) — if the slot has been inactive for more than 5 minutes, Debezium is disconnected and WAL is piling up.

6. **`invalidation_reason`** (Postgres 16+) — why the slot was invalidated: `wal_removed` (slot fell behind the size cap), `wal_level_insufficient` (someone downgraded wal_level), `rows_removed` (VACUUM removed rows before Debezium consumed them — requires REPLICA IDENTITY FULL).

## Alert Thresholds

| Alert | Condition | Action |
|---|---|---|
| Warning | `safe_wal_size < 50 GB` | Investigate Debezium health within the hour |
| Critical | `safe_wal_size < 10 GB` or `safe_wal_size < 0` | Page on-call immediately |
| Critical | `wal_status IN ('unreserved', 'lost')` | Page on-call |
| Critical | `inactive_since < now() - interval '5 minutes'` | Page on-call — consumer is disconnected |

## The Safety Net: `max_slot_wal_keep_size`

Set this in `postgresql.conf` before turning on Debezium in production:

```
max_slot_wal_keep_size = 50GB
```

If a slot falls behind by more than 50 GB, Postgres auto-invalidates it rather than letting WAL fill the disk. Your CDC pipeline goes down, but your application database stays up. That's the right tradeoff.

When a slot gets invalidated: drop it, recreate it at the current WAL position, restart Debezium with `snapshot.mode: never`, and backfill the missed window from Postgres via a targeted `MERGE INTO`.

## Heartbeat Events for Idle Tables

If you have low-traffic tables (feature flags, config tables), add Debezium heartbeats:

```json
{
  "heartbeat.interval.ms": "30000",
  "heartbeat.action.query": "INSERT INTO public.debezium_heartbeat (id, heartbeat_at) VALUES (1, now()) ON CONFLICT (id) DO UPDATE SET heartbeat_at = now()"
}
```

Heartbeats keep `confirmed_flush_lsn` advancing even on quiet tables, so the slot can release old WAL segments. Without them, a slot on a low-traffic table can trigger `max_slot_wal_keep_size` even though Debezium is working fine.
