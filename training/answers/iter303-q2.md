# Answer to Q2: Iceberg Time-Travel — Querying Historical Snapshots for Incident Debugging

## Yes — Iceberg's time-travel is exactly what you need

Iceberg keeps a snapshot history for every write. You can query the table as it existed at any past moment, compare before and after the bad write, and identify exactly which rows were affected.

## Two ways to query historical state

**By timestamp (approximate):**
```sql
SELECT *
FROM iceberg.analytics.events
FOR TIMESTAMP AS OF TIMESTAMP '2026-05-26 14:00:00 UTC'
WHERE event_date = DATE '2026-05-26';
```

**By exact snapshot ID (precise):**
```sql
SELECT *
FROM iceberg.analytics.events
FOR VERSION AS OF 4823511203987654321;
```

Key difference: `FOR TIMESTAMP AS OF` resolves to the **latest snapshot committed at or before** that timestamp. If the last write before 2 PM was at 1:45 PM, that's the snapshot you get. For incident debugging, use snapshot IDs — they're unambiguous.

## Step 1: Find the right snapshot

Use the `$snapshots` metadata table to find what was written during your 6-hour incident window:

```sql
SELECT snapshot_id, committed_at, operation, summary
FROM iceberg.analytics."events$snapshots"
WHERE committed_at BETWEEN TIMESTAMP '2026-05-26 08:00:00 UTC'
                       AND TIMESTAMP '2026-05-26 14:00:00 UTC'
ORDER BY committed_at;
```

This shows every snapshot created during that window, with the operation type (`overwrite`, `append`, `delete`). The bad writes will be visible here.

To see the full ordered history of what was "live" at each moment:

```sql
SELECT *
FROM iceberg.analytics."events$history"
ORDER BY made_current_at DESC
LIMIT 20;
```

## Step 2: Compare before vs after to find affected rows

Once you have the bad snapshot ID and the good snapshot ID (just before the bug started):

```sql
-- Rows added by the bug (in bad snapshot but not in good):
SELECT bad.*, 'ADDED_BY_BUG' AS change_type
FROM iceberg.analytics.events FOR VERSION AS OF <bad_snapshot_id>  bad
FULL OUTER JOIN
     iceberg.analytics.events FOR VERSION AS OF <good_snapshot_id> good
  ON bad.id = good.id
WHERE good.id IS NULL;

-- Rows with changed values between snapshots:
SELECT bad.id, bad.corrupted_column AS bad_value,
               good.corrupted_column AS good_value
FROM iceberg.analytics.events FOR VERSION AS OF <bad_snapshot_id>  bad
JOIN iceberg.analytics.events FOR VERSION AS OF <good_snapshot_id> good
  ON bad.id = good.id
WHERE bad.corrupted_column <> good.corrupted_column;
```

This is ground-truth comparison — no guessing about what should have been there.

## How long does time-travel last?

Iceberg retains snapshots until they're explicitly expired. Two limits apply on your stack:

1. **Trino 467 enforces a 7-day minimum floor.** `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '3d')` is rejected with an error if the threshold is under 7 days. You cannot expire snapshots younger than 7 days from Trino.

2. **Your table's configured retention.** Run `SHOW TBLPROPERTIES iceberg.analytics.events` and look for `history.expire.max-snapshot-age-ms`. Most production setups use 30 days.

**For your incident last week:** if routine maintenance runs with 30-day retention (the standard), your snapshots are still queryable right now with no special action needed.

Check right now:
```sql
SELECT snapshot_id, committed_at
FROM iceberg.analytics."events$snapshots"
ORDER BY committed_at DESC
LIMIT 5;
```

If your incident snapshots appear here, they're still alive.

## Incident recovery workflow

**Option A — Fix in place (least disruptive):**
1. Use the comparison query to identify bad rows
2. Run a corrective `UPDATE` or `INSERT OVERWRITE` on just those rows
3. The bad snapshot stays in history (still queryable), but the current table is fixed

**Option B — Hard rollback (safest for large-scale bad write):**
```sql
-- Spark-only rollback (reverts table pointer to before the bad write):
CALL iceberg.system.rollback_to_snapshot('analytics', 'events', <good_snapshot_id>);
```

This is metadata-only — no data is rewritten. The table pointer moves back to the good snapshot. The bad snapshot files remain in MinIO but are no longer referenced by the current table.

**Trino rollback syntax** (Trino 469+; check your version):
```sql
ALTER TABLE iceberg.analytics.events
EXECUTE rollback_to_snapshot(snapshot_id => <good_snapshot_id>);
```
On Trino 467, use the Spark form above.

## Preserving snapshots for forensics

If you need to keep a specific snapshot indefinitely (beyond normal retention, e.g., for audit or legal), tag it in Spark before maintenance runs:

```sql
-- Spark only (Trino cannot create tags):
ALTER TABLE iceberg.analytics.events
  CREATE TAG `incident-20260526`
  AS OF VERSION <snapshot_id>
  RETAIN 90 DAYS;
```

Tagged snapshots are never expired by `expire_snapshots` regardless of retention policy. You can query them from either Trino or Spark.

## For your specific incident

Given the incident happened last week and routine 30-day retention is likely:
1. Run the `$snapshots` query to confirm the incident snapshots are still there
2. Identify the last-good and first-bad snapshot IDs
3. Use the comparison queries to enumerate affected rows
4. Fix via corrective write or rollback depending on scope
5. Tag the incident snapshot now if you need it for more than 30 days
