# Iter98 Q2 — Answer

**Question**: We're using CDC to sync our Postgres tables into Iceberg, and I'm trying to understand what happens when a row gets deleted in Postgres. The CDC tool emits a delete event — I've seen it, it has an `op='d'` field and the old row values. But I'm not sure how that translates when we run the merge step that writes it into Iceberg. Does the row actually disappear from the Iceberg table? And I've heard that Iceberg keeps old snapshots around for a while before cleaning them up — does that mean deleted rows are still readable if someone queries an old snapshot, and is that a problem we need to worry about for compliance reasons?

---

## Answer

## How DELETE CDC events flow through MERGE INTO

When Debezium captures a delete from Postgres WAL, it emits an event with `op='d'`. The `before` field contains the deleted row's values (including the primary key); `after` is null. Your Spark MERGE INTO handles it with the `WHEN MATCHED AND s.op = 'd' THEN DELETE` clause:

```sql
MERGE INTO iceberg.analytics.events t
USING events_delta s
ON t.event_id = s.event_id
WHEN MATCHED AND s.op = 'd' THEN DELETE
WHEN MATCHED AND s.op = 'u' THEN UPDATE SET *
WHEN NOT MATCHED AND s.op IN ('c', 'r') THEN INSERT *
```

When the delete clause fires, Iceberg **logically marks the row as deleted** — it writes a small **delete file** (a marker saying "ignore rows matching this key"). The original Parquet data file is left untouched on MinIO. All subsequent queries skip the deleted row, but the bytes are still physically present.

## What happens with snapshots — yes, deleted rows are still readable

Every Iceberg operation creates a new snapshot. The delete operation produces a snapshot that points to the original data files plus the new delete files. But the **previous snapshot** — the one before the delete — still exists in the table's history and still references the original data file where the deleted row lives.

**Deleted rows ARE still readable via time-travel queries:**

```sql
-- This returns the deleted row if executed during the retention window
SELECT * FROM iceberg.analytics.events
FOR SYSTEM_TIME AS OF TIMESTAMP '2026-05-10 00:00:00';
```

This is intentional — Iceberg's time-travel is a feature. But it means deleted data persists until you explicitly run maintenance to expire old snapshots and remove the underlying files.

## The three-step sequence that physically removes deleted data

A logical delete (MERGE INTO with `op='d'`) is only step 1. You need all three steps to physically remove bytes from MinIO:

**Step 1: Apply the delete** (MERGE INTO — already running)
Creates delete files. Original data files remain. Bytes not yet removed.

**Step 2: Compact and apply deletes** (rewrites Parquet without deleted rows)
```sql
CALL iceberg.system.rewrite_data_files(table => 'analytics.events');
```
Spark reads affected files, drops deleted rows, writes new clean Parquet files. New snapshot points at clean files. Old files still referenced by prior snapshot — still not removed.

**Step 3: Expire old snapshots + remove orphan files** (physically deletes from MinIO)
```sql
CALL iceberg.system.expire_snapshots(
  table        => 'analytics.events',
  older_than   => current_timestamp() - INTERVAL '7' DAY,
  retain_last  => 1
);

CALL iceberg.system.remove_orphan_files(
  table      => 'analytics.events',
  older_than => current_timestamp() - INTERVAL '3' DAY
);
```

Only after step 3 does MinIO receive DELETE calls for the original Parquet files. **Only then are the bytes physically gone.**

## Yes, this is a compliance problem — here's what to do

If you have GDPR, data residency, or legal-hold requirements, the default Iceberg behavior (30-day snapshot retention) means deleted rows are still accessible for up to 30 days post-deletion.

**Three compliance scenarios:**

### Standard tables (no personal data)
Weekly maintenance with standard retention is fine:
- Run steps 2 and 3 weekly; keep last 7 days of snapshots
- Time-travel is available for operational debugging
- No compliance risk for non-PII data

### GDPR-subject tables (personal data)
Add an on-demand purge job that runs immediately after a deletion request:
```sql
-- Immediate purge (zero-day retention)
CALL iceberg.system.rewrite_data_files(
  table => 'analytics.events',
  where => "user_id = 'deleted-user-123'"
);

CALL iceberg.system.expire_snapshots(
  table        => 'analytics.events',
  older_than   => current_timestamp() - INTERVAL '0' DAY,
  retain_last  => 1
);

CALL iceberg.system.remove_orphan_files(
  table      => 'analytics.events',
  older_than => current_timestamp() - INTERVAL '1' DAY
);
```

Run the Spark version (not Trino) for `expire_snapshots` to bypass Trino's 7-day minimum retention floor.

### Alternative: soft deletes + view filtering

Instead of MERGE INTO DELETE, some teams use soft deletes — a `deleted_at` timestamp column. Rows are never deleted from Iceberg; they're marked. A Trino view hides soft-deleted rows:

```sql
CREATE VIEW analytics.events_live AS
  SELECT * FROM analytics.events
  WHERE deleted_at IS NULL;
```

This avoids the snapshot-retention compliance problem entirely (no physical delete to manage), but requires your GDPR purge path to use the full 4-step sequence (`DELETE → rewrite → expire → orphan cleanup`) when a user actually requests erasure.

## Practical recommendation

1. **Schedule weekly maintenance** (rewrite + expire + orphan cleanup) regardless of deletion volume — this handles ordinary operational deletes.
2. **Add an on-demand GDPR purge** for user deletion requests — run the immediate-expiry version within 24–48 hours of the request.
3. **Test the full purge path in staging** before going to production. The three-step sequence is non-optional for compliance — skipping `expire_snapshots` or `remove_orphan_files` leaves bytes on disk.
4. **Document your retention policy**: how long snapshots survive, when physical removal runs. Auditors want a clear answer, not "we have time travel."
