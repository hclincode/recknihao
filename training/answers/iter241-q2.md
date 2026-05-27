# Iter241 Q2 — Iceberg Snapshot Expiration + Time-Travel Failure Recovery

## What happened and why your query failed

Your data platform team's `expire_snapshots` cleanup job removed the old snapshot that your audit job was trying to reference with `FOR TIMESTAMP AS OF`. Here's the mechanism:

When you run `SELECT ... FROM iceberg.event_table FOR TIMESTAMP AS OF '2026-05-20 12:00:00'`, Iceberg looks for a snapshot with a `committed_at` timestamp on or before that date. If that snapshot is old (say, 35 days old) and your `expire_snapshots` job runs with a 30-day retention window, the old snapshot's **metadata is deleted** from Iceberg's snapshot list. Even though the underlying Parquet data files still exist on your storage, **the snapshot that points to them is gone**. Your audit query then fails because it cannot find a valid snapshot to resolve that timestamp to.

This is a common situation: Iceberg separates the concept of **data file retention** from **snapshot metadata retention**. When `expire_snapshots` removes a snapshot, it also marks the data files that *only* that snapshot referenced as eligible for cleanup. Your cleanup job probably ran `remove_orphan_files` afterward, which physically deleted those files from your object storage (MinIO or S3).

---

## How to prevent this from breaking again

There are three layers of defense:

### 1. Adjust your table-level retention policy (long-term, low-risk)

Set a table-level retention floor that auto-protects your audit window. If your audits always look back 60 days, enforce that at the table level:

```sql
-- Run this once from Spark SQL
ALTER TABLE iceberg.analytics.events
SET TBLPROPERTIES (
    'history.expire.min-snapshots-to-keep' = '10',
    'history.expire.max-snapshot-age-ms'   = '5184000000'  -- 60 days in milliseconds
);
```

After this, if someone schedules `expire_snapshots(retention_threshold => '30d')`, the table-level property still protects 60 days — the property floor always wins. The `min-snapshots-to-keep` is a secondary safety net: even if time passes very quietly and only 2 snapshots exist, keep the last 10 anyway.

**Caveat:** Trino 467 enforces its own 7-day minimum-retention floor (`iceberg.expire-snapshots.min-retention`). If your audit window is shorter than 7 days, you must run snapshot expiry from **Spark**, not Trino, because Spark does not enforce this floor.

### 2. Adjust your cleanup schedule and thresholds (medium-term, operationally safe)

If your audits look back 60 days but your cleanup job expires snapshots every 30 days, you have a 30-day gap. Increase the gap or coordinate the timing:

```sql
-- Safer: expire snapshots only after 60 days (Trino 467 form)
ALTER TABLE iceberg.analytics.events
EXECUTE expire_snapshots(retention_threshold => '60d');

-- Or (Spark form, same operation):
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.events',
  older_than  => current_timestamp() - interval '60' day,
  retain_last => 10
);
```

Document this alongside your cleanup job configuration. Make it a requirement in your runbook that **before changing snapshot retention thresholds, verify which queries (audits, billing, compliance) depend on historical snapshots and cannot lose access.**

### 3. Tag audit-critical snapshots (the stable long-term solution)

For audit snapshots you know you'll need later, **pin them with Iceberg tags**. Tags are **immune to expiration** — `expire_snapshots` will never remove a tagged snapshot, no matter how aggressive the retention window. This is the pattern used for billing-period closes and compliance audits.

Here's the workflow:

**Step 1: Identify the snapshot you need to pin:**

```sql
-- Run from Trino or Spark
SELECT snapshot_id, committed_at, operation
FROM iceberg.analytics."events$snapshots"
WHERE committed_at <= TIMESTAMP '2026-05-20 12:00:00'
ORDER BY committed_at DESC
LIMIT 1;
-- Returns snapshot_id 4823511203987654321
```

**Step 2: Create a tag to pin it (Spark only — Trino cannot CREATE tags):**

```sql
-- Run from Spark SQL
ALTER TABLE iceberg.analytics.events
  CREATE TAG `audit-2026-05-20`
  AS OF VERSION 4823511203987654321
  RETAIN 365 DAYS;
```

The `RETAIN 365 DAYS` means the tag itself expires after a year (if you forget to drop it). Omit it for "keep forever until I explicitly drop it."

**Step 3: Reference it in your audit queries:**

```sql
-- Query from Trino or Spark — both can read by snapshot ID
SELECT ... FROM iceberg.analytics.events
FOR VERSION AS OF 4823511203987654321
WHERE ...
```

**Step 4: Drop the tag when the audit window closes:**

```sql
-- Run from Spark SQL
ALTER TABLE iceberg.analytics.events DROP TAG `audit-2026-05-20`;
```

---

## The stable pattern for long-lived audit anchors

Here's the recommended pattern for a nightly audit job that must always succeed:

**Option A: Use snapshot IDs with tagging (most reliable for long-term audits).**

```python
# Nightly audit job (Spark + Trino)
from pyspark.sql import SparkSession

spark = SparkSession.builder.getOrCreate()

# Step 1: Find the snapshot as of yesterday at midnight (Spark query)
snapshot_query = """
SELECT snapshot_id FROM iceberg.analytics."events$snapshots"
WHERE committed_at <= TIMESTAMP '2026-05-26 00:00:00 UTC'
ORDER BY committed_at DESC LIMIT 1
"""
snapshot_id = spark.sql(snapshot_query).collect()[0][0]

# Step 2: Run your audit (reference by snapshot ID, not timestamp)
audit_result = spark.sql(f"""
SELECT COUNT(*) AS row_count
FROM iceberg.analytics.events FOR VERSION AS OF {snapshot_id}
WHERE event_date = '2026-05-25'
""").collect()[0]

# Optional: if this is month-end or quarter-end, tag it for compliance
# spark.sql(f"ALTER TABLE iceberg.analytics.events CREATE TAG `audit-2026-05-26` AS OF VERSION {snapshot_id}")
```

**Why this is stable:**
- You query `$snapshots` to find the exact snapshot_id, not relying on timestamp resolution (which can be ambiguous).
- You reference by snapshot ID in your audit join, which is an exact, unambiguous pointer.
- If you tag important snapshots, they survive routine cleanup forever.
- The query is reproducible — running it again on the same snapshot ID gives the same result.

**Option B: If you run audits frequently (daily/weekly), adjust retention to always cover your window:**

```sql
-- Set table-level policy: keep at least 90 days of snapshots
ALTER TABLE iceberg.analytics.events
SET TBLPROPERTIES (
    'history.expire.max-snapshot-age-ms' = '7776000000'  -- 90 days
);

-- Then use FOR TIMESTAMP AS OF safely, knowing the snapshot will exist
SELECT ... FROM iceberg.analytics.events
FOR TIMESTAMP AS OF TIMESTAMP '2026-05-26 00:00:00 UTC'
```

---

## Caveats about joining with PostgreSQL using historical snapshots

When you join an Iceberg historical snapshot against a live PostgreSQL table, you're comparing data from different points in time. This is fine if you understand the asymmetry:

1. **The Iceberg side is locked to a specific snapshot.** You're reading a frozen point-in-time version of the events.
2. **The PostgreSQL side is live.** You're reading the current state of the customer table.

Predicate pushdown and dynamic filtering still work with time-travel:
- The snapshot is resolved at plan time; the Iceberg scan proceeds with normal partition pruning, min/max stats, and manifest file filtering
- Dynamic filtering from the PostgreSQL build side (if accounts is the smaller table) still pushes an IN-list to the Iceberg probe scan
- The cross-catalog join executes on Trino workers — Postgres doesn't see the Iceberg snapshot and vice versa

If your goal is "reproduce the exact state as it was at time T in both systems," you need a denormalized `customers_snapshot` table in Iceberg that was also captured at time T. **Trino 467 does not support PostgreSQL historical queries directly** (federation works only for the live PostgreSQL schema).

---

## Summary: What to do today

1. **Immediate:** Check your data platform team's `expire_snapshots` configuration. If it's expiring snapshots younger than your audit lookback window, raise the threshold or add table-level retention properties (see above).

2. **Short-term:** Modify your audit job to reference snapshots by ID instead of timestamp:
   - Query `$snapshots` for the exact snapshot_id at your audit cutoff.
   - Use `FOR VERSION AS OF <snapshot_id>` instead of `FOR TIMESTAMP AS OF`.
   - This makes the audit deterministic and survives retention-policy changes.

3. **Long-term:** For compliance-critical snapshots, tag them with `ALTER TABLE ... CREATE TAG` in Spark. Tagged snapshots are permanent and queryable by name.

4. **Coordination:** Document your audit requirements in the same runbook as your cleanup procedures. Snapshot retention is a resource trade-off — auditors want it long, operators want it short. Make the trade-off explicit and reviewed by both teams.
