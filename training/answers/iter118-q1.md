# Iter118 Q1 — Answer

**Question**: One of our enterprise customers is asking us to prove that their usage report from Q1 was accurate — their finance team is disputing some numbers from three months ago and wants us to reproduce the exact same report as it ran on January 15th. In Postgres I have no way to do this because the underlying data has changed since then. I've heard that Iceberg has some kind of "time travel" feature. Can you explain how that actually works in practice — like, what do I need to do in a SQL query to reproduce a report from a specific past date, and is there any catch around how long that historical data stays available?

---

# Iceberg Time Travel: Querying Historical Data

## The Problem You're Solving

In Postgres, every UPDATE rewrites data in place. Once three months have passed, the original numbers are gone. Iceberg is different—it never modifies files in place. Instead, every write creates a new "snapshot" (a point-in-time version of the table). You can query any past snapshot as if it still exists.

## How It Actually Works in Practice

Iceberg builds a chain of snapshots over time. Each snapshot is a metadata pointer to a set of Parquet data files as they existed at that moment. When your ingestion job ran on January 15th, it created a snapshot. That snapshot still references the exact files that existed then. To reproduce the Q1 report, you query that specific snapshot.

## The SQL Syntax

You can time-travel using either a timestamp or a snapshot ID. Here's how to query the table **as it existed on January 15th**:

```sql
-- Query by timestamp (simpler, what you probably want)
SELECT *
FROM iceberg.analytics.usage_report
FOR TIMESTAMP AS OF TIMESTAMP '2026-01-15 00:00:00'
WHERE customer_id = 'acme-corp';
```

Or if you know the exact snapshot ID:

```sql
-- Query by snapshot ID (more precise, useful if multiple writes happened that day)
SELECT *
FROM iceberg.analytics.usage_report
FOR VERSION AS OF 4823511203987654321
WHERE customer_id = 'acme-corp';
```

To find the right snapshot ID for January 15th, query the table's metadata:

```sql
-- Find snapshots near the target date
SELECT snapshot_id, committed_at, operation
FROM iceberg.analytics."usage_report$snapshots"
WHERE committed_at >= TIMESTAMP '2026-01-15 00:00:00'
  AND committed_at < TIMESTAMP '2026-01-16 00:00:00'
ORDER BY committed_at DESC;
```

This shows you every write that happened that day. If your report job ran at 9 AM, pick the snapshot committed closest to that time.

## The Critical Catch: Snapshot Retention

Here's the important part: **snapshots don't live forever.** Your Iceberg maintenance job (which should be running weekly) includes an `expire_snapshots` procedure that deletes old snapshots. On this stack, the default is **7 days minimum** (enforced by Trino; Spark has no minimum). Many teams extend it to 30 days for a safer rollback window.

**This means:**
- **January 15th report — recoverable until ~7–30 days after you run `expire_snapshots`** (typically 7–30 days from January 15th depending on your retention settings)
- **If `expire_snapshots` already ran and the snapshot is gone, time travel is impossible** — you have no way to recover that exact historical state

If your customer's finance team asks about data from three months ago and you've been running standard maintenance, you likely cannot answer them. The snapshot is gone.

## What To Do Right Now

1. **Check if the snapshot still exists** — run the metadata query above for January 15th. If it returns results, the snapshot is still alive.

2. **If it exists, reproduce the report immediately:**
   ```sql
   -- Run the exact query your report job ran, but add FOR TIMESTAMP AS OF
   SELECT customer_id, usage_amount, billing_period
   FROM iceberg.analytics.usage_report
   FOR TIMESTAMP AS OF TIMESTAMP '2026-01-15 09:00:00'  -- adjust to when report ran
   WHERE billing_period = '2026-Q1';
   ```

3. **If it doesn't exist, you need a fallback** — either:
   - Query the latest data and explain the discrepancy (if data was corrected between January 15th and now)
   - Use write-once event logs or immutable backups if you have them outside Iceberg
   - Check if you kept a separate archive table from that period

## The Long-Term Fix

Prevent this from happening again:

- **Extend snapshot retention to 90+ days** if your storage can afford it. On this stack, that means adjusting the `older_than` parameter in your weekly `expire_snapshots` call from 7 days to 90 days:

  ```sql
  -- Spark SQL (run weekly as part of maintenance)
  CALL iceberg.system.expire_snapshots(
    table       => 'analytics.usage_report',
    older_than  => current_timestamp - interval '90' day,
    retain_last => 10
  );
  ```

- **For audit-critical tables (billing, usage, compliance), run this longer retention.** For transient tables (cache, staging), 7 days is fine.

- **Document your snapshot retention policy.** Finance needs to know: "We can reproduce reports from the last 90 days. Anything older requires manual intervention."

## Why Your Postgres Approach Doesn't Work Here

Postgres overwrites rows in place. Once the row changes, the old value is gone (unless you have a separate audit table). Iceberg is the opposite—it **appends immutable snapshots** and never touches old data. The cost is that old snapshots consume storage until they're explicitly expired. But the benefit is that you *can* answer questions like your customer's, as long as you kept the snapshot.
