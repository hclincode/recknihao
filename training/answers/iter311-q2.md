# Answer to Q2: Replication Slot Early-Warning States and Headroom (Iter 311)

Yes, `lost` is too late. Postgres gives you a multi-stage warning system before that happens.

## The Four wal_status States

When you query `pg_replication_slots.wal_status`, there are four states:

1. **`reserved`** — healthy. Postgres is holding the WAL your slot needs, and you're safely within normal retention limits.

2. **`extended`** — your slot is holding WAL beyond what Postgres would normally keep (beyond `max_wal_size`), but it's still safe. Yellow-flag territory — monitor closely but not an emergency yet.

3. **`unreserved`** — **this is your actionable warning state.** The slot is at risk of invalidation; the WAL it needs may be gone very soon. When you see `unreserved`, you have limited time to intervene — either restart your Debezium connector to get it unstuck, or increase `max_slot_wal_keep_size` if the outage is legitimate and acceptable. Once a slot reaches `unreserved`, the next automated Postgres housekeeping run can flip it to `lost` at any moment.

4. **`lost`** — invalidated and unrecoverable. The WAL is already gone. This requires the four-step recovery runbook: drop the slot, recreate it, restart Debezium with `snapshot.mode: never`, and backfill the gap via `MERGE INTO` from your Postgres primary.

**Alert on `unreserved`, not `lost`**. By the time you see `lost`, you're in an outage with no in-place recovery.

## Measuring Headroom Before the Slot Is Dropped

Postgres doesn't expose a direct "bytes remaining before invalidation" column, but you can calculate it from columns already in `pg_replication_slots`:

```sql
SELECT 
    slot_name, 
    active, 
    wal_status,
    pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS bytes_behind
FROM pg_replication_slots
WHERE slot_name = 'debezium_slot';
```

Then in your monitoring system:

```
headroom_bytes = max_slot_wal_keep_size_setting - bytes_behind
```

If you've set `max_slot_wal_keep_size = 50GB` and your query shows `bytes_behind = 40GB`, you have `10GB` left before auto-invalidation.

## Recommended Alert Tiers

| Alert | Condition | What to do |
|---|---|---|
| **Warning** | `bytes_behind > 50 GB` | Investigate Debezium health |
| **Critical** | `bytes_behind > 150 GB` OR `> 80% of your max_slot_wal_keep_size` | Page immediately |
| **Critical** | `wal_status = 'unreserved'` | Page immediately — slot at risk of auto-drop |
| **Critical** | `wal_status = 'lost'` | Start recovery runbook (already in outage) |
| **Warning** | `active = false` for >5 minutes | Debezium disconnected, WAL accumulating |

Alert on `unreserved` as a named condition — don't rely solely on `bytes_behind` thresholds, because WAL generation rate spikes (a big bulk import, a migration) can skip past your threshold windows.

## One More Critical Detail: Heartbeat for Idle Tables

If you have low-traffic tables (a permissions table, a config table, a feature flags table that rarely changes), wire `heartbeat.interval.ms` on the Debezium connector:

```json
{
  "heartbeat.interval.ms": 30000,
  "heartbeat.action.query": "INSERT INTO debezium_heartbeat (slot_name) VALUES ('debezium_slot')"
}
```

Without it, those quiet tables can cause `confirmed_flush_lsn` to never advance even though the consumer is healthy — because Debezium has no events from those tables to acknowledge. This leads to false alerts and, in worst cases, actual slot invalidation from pure idleness. The heartbeat ensures the slot's position advances on a 30-second cadence even with zero CDC events.
