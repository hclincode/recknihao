# Iter 216 Q2 — Iceberg Snapshot Expiry and Time Travel: What Gets Deleted and How to Retain History

## Answer

## What `expire_snapshots` deletes and why your time travel broke

**What `expire_snapshots` actually deletes:** It deletes **snapshot metadata**, not the underlying Parquet data files directly. A snapshot is Iceberg's point-in-time record — it's a pointer to a set of manifest files that list which data files were live at that moment. When you run `expire_snapshots`, you remove old snapshots from the table's history. Once a snapshot is gone, **no one can time-travel to it**.

The catch that bit you: the data files those old snapshots referenced become eligible for deletion *only after* `expire_snapshots` runs *and* any files that are **no longer referenced by any living snapshot** get physically removed from MinIO (either by `expire_snapshots` itself or by `remove_orphan_files` in a second step). This is exactly what happened — your storage dropped because those orphaned files got deleted.

---

## How Iceberg decides which files are safe to delete

**Files are safe to delete only if NO live snapshot still references them.** This is Iceberg's core safety guarantee:

- After you delete data via `DELETE FROM ...` or overwrite it via `UPDATE`, Iceberg creates a new snapshot pointing at the new files.
- The old files are no longer referenced by the *current* snapshot, but they ARE still referenced by *prior* snapshots (the ones Iceberg kept for time travel).
- Until `expire_snapshots` removes those prior snapshots, the old files cannot be touched.
- Once the prior snapshots are expired, those files become "orphans" — unreferenced by any snapshot. `expire_snapshots` itself issues the S3 DELETE calls, or `remove_orphan_files` sweeps them in a second pass.

**A file referenced by any snapshot is protected** — even if you're about to expire that snapshot. The procedure checks: "Does any live snapshot point to this file?" If yes, keep it. If no (and the file has been sitting unreferenced long enough), delete it.

---

## How to keep history for time travel while freeing storage

You need to balance two competing needs: retain enough snapshots for time travel, but expire old ones to reclaim storage. Here are your configuration options:

**Option 1: Set per-call retention when expiring (what you control each run)**

```sql
-- Trino 467 (most straightforward)
ALTER TABLE iceberg.analytics.events 
EXECUTE expire_snapshots(retention_threshold => '30d');

-- Spark (if you need more control)
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.events',
  older_than  => current_timestamp - interval '30' day,
  retain_last => 10
);
```

- `retention_threshold` (Trino) or `older_than` (Spark): delete snapshots older than this age. Set it to however far back you want time travel to work (7 days, 30 days, 90 days).
- `retain_last` (Spark only): always keep the N most recent snapshots regardless of age — a safety net for quiet tables.

**Option 2: Set table-level properties as a durable floor (recommended for production)**

```sql
ALTER TABLE iceberg.analytics.events
SET TBLPROPERTIES (
    'history.expire.min-snapshots-to-keep' = '5',
    'history.expire.max-snapshot-age-ms'   = '2592000000'  -- 30 days in milliseconds
);
```

These properties enforce a minimum retention that applies *every time* `expire_snapshots` runs, regardless of what arguments are passed:

- `history.expire.min-snapshots-to-keep` (default `1`): always keep at least this many recent snapshots by count.
- `history.expire.max-snapshot-age-ms` (default 5 days): always keep snapshots younger than this age.

If you set these once, they become sticky policy — a teammate can't accidentally run an aggressive expiry that breaks your time-travel window.

**Option 3: Important constraint on Trino (the 7-day minimum floor)**

Trino 467 enforces a hard minimum retention floor of **7 days** via the `iceberg.expire-snapshots.min-retention` catalog property. You cannot expire snapshots younger than 7 days from Trino, even if you want to. If you need to keep snapshots for only 1–3 days (tighter storage control), **run the expiry from Spark instead** — Spark has no such floor. Alternatively, lower the Trino catalog property and restart the coordinator (operationally heavy).

---

## Minimum retention for safe time travel

**For a typical SaaS application:** 7–30 days is the safe range:

- **7 days** (Trino's hard minimum): safe if your support team always resolves billing disputes within a week, and your audit window is short.
- **30 days** (common operator choice): balances time travel depth (covers most month-end queries) against storage cost. Iceberg's own default is 5 days, Trino's hard minimum is 7 days, so 30 is a conservative pick.
- **90 days** (longer compliance windows): for regulated data (HIPAA, SOX, PCI-DSS billing records). Costs more storage but keeps full quarter-end audit history.

**How to diagnose what went wrong on your table:**

```sql
-- See what's currently set on the table
SHOW TBLPROPERTIES iceberg.analytics.events;

-- Find when snapshots were created
SELECT snapshot_id, committed_at, operation
FROM iceberg.analytics."events$snapshots"
WHERE committed_at > current_timestamp - interval '7' day
ORDER BY committed_at DESC;
```

**The fix going forward:**

```sql
-- Set a 30-day floor that will survive future expire_snapshots runs
ALTER TABLE iceberg.analytics.events
SET TBLPROPERTIES (
    'history.expire.max-snapshot-age-ms' = '2592000000'  -- 30 days
);

-- Then schedule expire_snapshots with matching retention
ALTER TABLE iceberg.analytics.events 
EXECUTE expire_snapshots(retention_threshold => '30d');
```

---

## Key takeaway on the maintenance order

Always run maintenance in this order: compaction → `expire_snapshots` (with adequate retention) → `remove_orphan_files`. Running expiry alone with a short threshold will break time travel. The combination of all three, run in order with defensible retention settings, keeps the system healthy.
