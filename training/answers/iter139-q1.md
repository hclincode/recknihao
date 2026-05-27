# Iter139 Q1 — Answer

**Question**: "We're thinking about using time travel queries in Iceberg to let customers see what their data looked like 'as of last week' — they're asking for some kind of audit view on their usage dashboards. I know Iceberg keeps old snapshots around, but I'm not sure how this actually works or what the risks are. Can I just run a SELECT against an old snapshot in production? And is there anything that would make an old snapshot unavailable — like if we ran our cleanup job?"

---

## How Time Travel Works in Iceberg

Iceberg keeps every historical snapshot of the table. Each snapshot is a pointer to a specific set of Parquet data files on MinIO. Time travel queries read those old data files directly — there's no reconstruction, no versioning magic, just the old files still sitting on MinIO.

### Trino Syntax

```sql
-- Query by timestamp (resolves to the latest snapshot at or before this time)
SELECT tenant_id, SUM(api_calls) AS calls
FROM iceberg.analytics.usage_report
FOR TIMESTAMP AS OF TIMESTAMP '2026-03-31 23:59:59 UTC'
WHERE billing_month = '2026-03'
GROUP BY tenant_id;

-- Query by snapshot ID (recommended for audits — unambiguous)
SELECT tenant_id, SUM(api_calls) AS calls
FROM iceberg.analytics.usage_report
FOR VERSION AS OF 4823511203987654321
WHERE billing_month = '2026-03'
GROUP BY tenant_id;
```

To find the right snapshot ID:

```sql
SELECT snapshot_id, committed_at, operation
FROM iceberg.analytics."usage_report$snapshots"
WHERE committed_at BETWEEN TIMESTAMP '2026-03-31 23:00:00 UTC'
                       AND TIMESTAMP '2026-04-01 02:00:00 UTC'
ORDER BY committed_at DESC
LIMIT 5;
```

**Why prefer snapshot ID over timestamp:** `FOR TIMESTAMP AS OF T` returns the latest snapshot with `committed_at <= T`. If your job committed at 09:03 but you query `FOR TIMESTAMP AS OF '09:00:00'`, you get the state *before* the job ran — not what you expected. For billing audits, pin the exact snapshot ID.

---

## What Can Make a Snapshot Unavailable

Two maintenance operations together make old snapshots unavailable:

### 1. `expire_snapshots` removes the snapshot metadata

```sql
-- Trino 467: removes snapshots older than 30 days from the snapshot history
ALTER TABLE iceberg.analytics.usage_report
EXECUTE expire_snapshots(retention_threshold => '30d');
```

After this runs, `FOR VERSION AS OF <old_snapshot_id>` fails with "snapshot not found" if that snapshot was older than 30 days.

### 2. `remove_orphan_files` physically deletes the old Parquet files from MinIO

```sql
-- Trino 467: deletes files no longer referenced by any live snapshot
ALTER TABLE iceberg.analytics.usage_report
EXECUTE remove_orphan_files(retention_threshold => '7d');
```

After `expire_snapshots` removes a snapshot, that snapshot's data files become orphans (unreferenced). When `remove_orphan_files` runs, it scans MinIO and physically deletes them. At that point, even if you somehow restored the snapshot metadata, the data files are gone.

**Both steps are required to actually free MinIO storage.** After step 1 alone, the files still exist on MinIO; after step 2, they're gone.

---

## The 7-Day Minimum Retention Floor in Trino 467

Trino 467 enforces a minimum retention floor:

- `iceberg.expire-snapshots.min-retention` — defaults to **7 days**
- `iceberg.remove-orphan-files.min-retention` — defaults to **7 days**

Passing `retention_threshold => '1d'` from Trino produces a procedure error. The minimum you can pass is `'7d'`. If you ever need sub-7-day purges (e.g., a GDPR right-to-erasure request), run from Spark instead (no floor).

---

## Designing a Retention Policy for Time Travel

| Retention | MinIO cost | Time travel window | Recommended for |
|---|---|---|---|
| `7d` (Trino minimum) | Lowest | 7 days | Storage-tight environments only |
| `30d` | Moderate | 30 days | Most SaaS use cases (billing disputes) |
| `90d` | Higher | 90 days | Compliance-heavy (SOX, HIPAA) |

**Practical setup (30-day retention):**

```sql
-- Run weekly (e.g., Sunday 3 AM)
ALTER TABLE iceberg.analytics.usage_report
EXECUTE expire_snapshots(retention_threshold => '30d');

-- Run after expire_snapshots to clean MinIO
ALTER TABLE iceberg.analytics.usage_report
EXECUTE remove_orphan_files(retention_threshold => '7d');
```

**Pinning a specific snapshot forever (for billing close-outs):**

```sql
-- Tag the March billing-close snapshot so it's never expired
CALL iceberg.system.create_tag(
    table       => 'analytics.usage_report',
    name        => '2026-03-billing-close',
    snapshot_id => 4823511203987654321
);
```

Tagged snapshots are retained regardless of the `expire_snapshots` retention window. Drop the tag when the dispute window closes.

---

## Are Time Travel Queries Safe to Run in Production Concurrently with Live Writes?

**Yes — completely safe.** Iceberg implements snapshot isolation. When a time travel query begins, it pins a specific snapshot and reads only the data files that snapshot referenced. Live ingestion creates new snapshots and new files — it does not touch the files the query is reading. No locks, no blocking.

**One edge case:** If `expire_snapshots` + `remove_orphan_files` runs *while* a long-running time travel query is executing, the files the query is reading could be deleted mid-query. In practice this is rare because:
- Queries run in seconds; maintenance jobs run on weekly schedules.
- The 7-day minimum floor on `remove_orphan_files` provides a safety buffer.

To be safe, schedule cleanup jobs in a maintenance window (e.g., early Sunday morning) when audit queries are unlikely.

---

## Summary

1. **Time travel syntax**: `FOR VERSION AS OF <snapshot_id>` (preferred for audits) or `FOR TIMESTAMP AS OF <timestamp>` in Trino.
2. **Snapshots become unavailable** when `expire_snapshots` removes the metadata AND `remove_orphan_files` deletes the data files. Both steps are required to actually lose data.
3. **Trino 467 minimum retention floor is 7 days** — never pass a shorter value.
4. **Set 30-day retention** for typical SaaS audit needs; tag billing-close snapshots to exempt them from expiry.
5. **Time travel is safe in production** — Iceberg snapshot isolation means queries are never blocked by concurrent writes.
