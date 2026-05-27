# Iter94 Q2 — Answer

**Question**: We're running Debezium to stream changes from Postgres into our data lake, and last week we had to restart the connector after it crashed. When it came back up it started doing what looked like a full table scan — reading every row from scratch — instead of just picking up from where it left off. We definitely had a replication slot already set up in Postgres and it hadn't been dropped. Is there a setting that controls whether Debezium does that full re-read on startup, and how do we tell it to just resume from the existing slot position instead of starting over?

---

## Answer

## What you saw: snapshot.mode=initial re-reading all rows

Debezium has a setting called `snapshot.mode` that controls what it does when it starts up. The default is `initial`, and that's almost certainly what triggered the full table re-read you saw.

With `snapshot.mode: initial`, Debezium checks whether it has already done a snapshot by looking at its internal offsets (stored in Kafka). If the offsets are missing or Debezium can't find them, it treats this as a "first run" and does a full snapshot — reading every row from every table as `op: "r"` (read) events, then switching to streaming from the WAL. This is the right behavior the very first time you deploy, but it's wrong on a restart where you want to resume from where you left off.

## The three snapshot.mode options

| Mode | What it does |
|---|---|
| `initial` (default) | Snapshots all pre-existing rows on first connect; skips snapshot if offsets already recorded |
| `never` | Always skips the snapshot; resumes from slot position; fails if slot is missing |
| `when_needed` | Only snapshots when the slot is missing or invalid |

The key distinction: `initial` checks **Debezium's own offset store** (in Kafka), not the replication slot. If the offset store was wiped, reset, or Debezium was redeployed with a new consumer group, it sees no offsets and re-snapshots — even though the Postgres slot is intact.

## The fix: set snapshot.mode to never

Add this to your connector config:

```json
{
  "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
  "snapshot.mode": "never",
  "plugin.name": "pgoutput",
  "topic.prefix": "app-db",
  "database.hostname": "postgres.internal",
  "database.port": "5432",
  "database.user": "debezium_user",
  "database.dbname": "appdb",
  "slot.name": "debezium_slot"
}
```

With `snapshot.mode: never`, Debezium will:
1. Connect to the replication slot named in `slot.name`
2. Start streaming from the slot's current position
3. **Never** attempt a full snapshot, even if offsets are missing

## Before restarting: verify the slot is healthy

First, confirm the replication slot exists and is not too far behind:

```sql
SELECT slot_name, active, restart_lsn, confirmed_flush_lsn
FROM pg_replication_slots
WHERE slot_name = 'debezium_slot';
```

- **`active`**: should be `false` (no one connected yet) or `true` (Debezium is actively streaming)
- **`restart_lsn`**: where Postgres must keep WAL from
- **`confirmed_flush_lsn`**: where Debezium last confirmed it read to

If `confirmed_flush_lsn` is very far behind `restart_lsn`, it means Debezium fell behind during the outage and there's a large backlog to replay. That's normal — it will catch up. If the slot was dropped (not your case, but for reference), `never` mode will fail immediately rather than silently re-snapshotting, which is the right behavior.

## When to use each mode

- **`never`**: use in production when you have a stable slot and want strict "resume from position" semantics. Any restart resumes from the slot. Fails loudly if the slot is gone.
- **`initial`**: use only on first-ever deploy when you need all historical rows in your data lake before streaming begins.
- **`when_needed`**: a middle ground — snapshots only when the slot is gone. Safer than `never` if you expect slot invalidation, but adds the risk of re-snapshotting unexpectedly after certain failure modes.

For your setup (existing slot, want to resume), `never` is the right choice.
