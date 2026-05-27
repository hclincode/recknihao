# Iter 146 Q2 — Iceberg Table Rollback After Accidental DELETE

## Answer

Yes — Iceberg keeps every version of the table as an immutable snapshot, and rolling back to before the DELETE is a single metadata operation. Here is exactly how to do it.

### How Iceberg versions work

Every write operation (INSERT, DELETE, UPDATE, MERGE) creates a new immutable snapshot. A snapshot is just a pointer to a set of Parquet data files — it does not copy data. The table's current state is determined by which snapshot the metadata currently points to. Rolling back means changing that pointer back to an earlier snapshot.

The deleted customer records still exist as Parquet files on disk — they are referenced by the snapshot that existed before the DELETE. Iceberg has not touched those files.

### Step 1: Find the snapshot to roll back to

Query the `$snapshots` metadata table to find the snapshot from before the DELETE:

```sql
SELECT snapshot_id, committed_at, operation, summary
FROM iceberg.analytics.customer_records$snapshots
ORDER BY committed_at DESC
LIMIT 20;
```

The `operation` column will show `delete` for the snapshot created by the accidental DELETE statement. You want the snapshot immediately before that one — the last snapshot with `operation = 'append'` or `overwrite` before the delete timestamp.

You can also use the `$history` table:

```sql
SELECT made_current_at, snapshot_id, parent_id, is_current_ancestor
FROM iceberg.analytics.customer_records$history
ORDER BY made_current_at DESC
LIMIT 20;
```

Note the `snapshot_id` of the last good state — for example, `4823511203987654321`.

### Step 2: Verify the snapshot has the data you expect

Before rolling back, confirm the pre-delete snapshot has the right row count using time travel:

```sql
-- Time travel to the pre-delete snapshot
SELECT COUNT(*) 
FROM iceberg.analytics.customer_records FOR VERSION AS OF 4823511203987654321;

-- Compare to current (post-delete) state
SELECT COUNT(*) 
FROM iceberg.analytics.customer_records;
```

The difference should match the number of deleted records. You can also spot-check individual rows:

```sql
SELECT customer_id, created_at 
FROM iceberg.analytics.customer_records FOR VERSION AS OF 4823511203987654321
WHERE created_at >= CURRENT_DATE - INTERVAL '7' DAY
LIMIT 10;
```

### Step 3: Roll back

With the snapshot ID confirmed, execute the rollback using Trino. On **Trino 467** (the current production version), use the `CALL` form with **positional** arguments `(schema, table, snapshot_id)`:

```sql
CALL iceberg.system.rollback_to_snapshot('analytics', 'customer_records', 4823511203987654321);
```

Note: the `ALTER TABLE ... EXECUTE rollback_to_snapshot(snapshot_id => ...)` syntax requires **Trino 469+** (released Jan 2025) and does NOT exist on Trino 467 — attempting it fails with a procedure / syntax error. On Trino 467 the CALL form above is the only supported rollback syntax. Do NOT use the Spark named-arg form (`table => '...', snapshot_id => ...`) from Trino either — Trino's CALL requires positional args.

This operation is:
- **Instant** — it only updates the metadata pointer, no data is copied or moved
- **Atomic** — any queries running during the rollback see either the old state or the new state, never an in-between
- **Non-destructive** — the DELETE snapshot is not removed, it is just no longer the current snapshot. You can still time-travel to it.

Verify the rollback succeeded:

```sql
SELECT COUNT(*) FROM iceberg.analytics.customer_records;
-- Should match the pre-delete count
```

### Time window — act before expire_snapshots

This only works while the old snapshots still exist. Iceberg's `expire_snapshots` maintenance procedure removes snapshots older than the retention period. Your table's retention is typically 7 days (Trino enforces a minimum of 7 days for both `expire_snapshots` and `remove_orphan_files`).

To check how much time you have, look at your table's snapshot properties:

```sql
SHOW CREATE TABLE iceberg.analytics.customer_records;
-- Look for write.metadata.delete-after-commit.enabled and
-- history.expire.max-snapshot-age-ms
```

If `expire_snapshots` has already run and removed the pre-delete snapshot, the data files it referenced may also be gone (if `remove_orphan_files` also ran). In that case, you cannot roll back and must reload from your source database.

### Handling Debezium CDC downstream

If Debezium is streaming changes from this table's source database into Iceberg, rolling back the Iceberg table creates a divergence — the source database still has the deletes applied, so Debezium will not re-emit the deleted rows. You have three options:

**Option A — Pause Debezium, rollback, replay from source**
1. Pause the Debezium connector
2. Roll back the Iceberg table
3. Reset the Debezium connector offsets to the LSN just before the DELETE was applied in Postgres
4. Resume — Debezium replays the missing week of events including the deleted records

**Option B — Roll back Iceberg, then INSERT the missing records directly**
Run a one-time load from your source database to fill in the deleted records, then let Debezium continue streaming from its current position. Simpler but requires the source database to still have the data.

**Option C — Accept the gap, reload from source**
If the Iceberg table is just a downstream analytics copy and the source database is authoritative, truncate the affected partition and reload it directly from the source, then resume Debezium from the current LSN.

### Summary

| Step | Command |
|---|---|
| Find pre-delete snapshot | `SELECT snapshot_id, committed_at, operation FROM ...$snapshots ORDER BY committed_at DESC LIMIT 20` |
| Verify data with time travel | `SELECT COUNT(*) FROM ... FOR VERSION AS OF <snapshot_id>` |
| Roll back (Trino 467) | `CALL iceberg.system.rollback_to_snapshot('<schema>', '<table>', <snapshot_id>)` (positional args; the `ALTER TABLE ... EXECUTE` form requires Trino 469+) |
| Confirm | `SELECT COUNT(*) FROM ...` — should match pre-delete count |

Act within 7 days of the DELETE — after `expire_snapshots` removes the old snapshot, the rollback path is gone and you must reload from source.
