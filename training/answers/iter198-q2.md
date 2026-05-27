# Iter 198 Q2 — Iceberg Snapshot Expiry and In-Flight Federation Queries

## Answer

**You should schedule maintenance windows and block queries during snapshot expiry, or run it during a low-traffic period. Iceberg does NOT automatically protect in-flight queries from snapshot expiry.**

Here's what actually happens:

**The risk is real.** When you run `expire_snapshots` and it deletes snapshot metadata pointing to Parquet files on MinIO, any Trino query that is already in-flight and reading from that snapshot can fail mid-execution with file-not-found errors. A long-running join against Postgres subscription tables that references an Iceberg event table is still a Trino query reading from Iceberg. If expiration deletes the snapshot and its files while the query is mid-scan, the query fails.

**Why this happens:** Iceberg uses snapshot isolation for *new* queries — when you start a query, Iceberg captures which snapshot you'll read from and holds onto that view for the duration of the query. However, snapshot isolation does **not** prevent the *actual data files* referenced by that snapshot from being deleted on MinIO. The `expire_snapshots` procedure deletes the manifest metadata first, then issues S3 DELETE calls to physically remove the Parquet files. A query that started before expiry began, but whose scanning phase happens during expiry, will try to fetch files that no longer exist.

---

## What You Should Do

**1. Schedule compaction (`rewrite_data_files`) separately from snapshot expiry.**

Compaction is safe to run concurrently with queries — it creates new snapshots while existing queries keep reading the old ones. Compaction does NOT delete any files that current snapshots point to; it only adds new, compacted files and registers a new snapshot. In-flight queries are not affected.

```sql
-- Safe to run while queries are active
ALTER TABLE iceberg.events.user_events EXECUTE optimize
WHERE date >= current_date - interval '7' day;
```

**2. Schedule `expire_snapshots` and `remove_orphan_files` during a low-query window.**

These are the dangerous operations for in-flight queries. The standard pattern:
- Run compaction at a different time (e.g., 4 AM)
- Run `expire_snapshots` during your quietest window (e.g., Sunday 3 AM)
- For customers in different time zones: accept a brief "maintenance window" of 20-40 minutes when you run expiry, or pick the time with lowest observed query rate

**3. Use generous retention thresholds.**

```sql
-- Safe default: only expire snapshots older than 7 days
CALL iceberg.system.expire_snapshots(
  schema_name => 'events',
  table_name => 'user_events',
  older_than => current_timestamp - interval '7' day,
  retain_last => 5
);
```

This greatly reduces the chance that an in-flight query is reading from something that old. Never use `older_than => current_timestamp` for routine maintenance — that aggressively expires the most recent snapshot and is the most likely cause of "flaky query failures during the maintenance window."

**4. The Trino minimum retention floor.**

Trino enforces a minimum retention of 7 days for `expire_snapshots` via the `iceberg.expire-snapshots.min-retention` catalog property (default: `7d`). Attempts to expire more aggressively are rejected. This is a safety net — don't override it in production.

---

## The Federated Query Interaction

Your specific concern about federated queries (Iceberg + Postgres join) makes the risk slightly higher, not lower. Here's why:

- A 10-15 minute Iceberg-only query has 10-15 minutes of exposure to expiry
- A 10-15 minute federated query joining Iceberg events against Postgres subscriptions has the same 10-15 minute exposure on the Iceberg side — the Postgres side is protected by Postgres's own MVCC (Postgres never deletes rows from under a running query)
- If the Iceberg portion fails mid-execution, the entire Trino query fails, including the Postgres join side

The Postgres connector is safe from this type of failure; only the Iceberg connector is at risk from snapshot expiry.

---

## Practical Recommendation

| Operation | Concurrent queries safe? | Notes |
|---|---|---|
| `rewrite_data_files` (compaction) | YES | Creates new snapshot; doesn't delete existing files |
| `expire_snapshots` | NO (within retention window) | Deletes files; in-flight queries can get file-not-found |
| `remove_orphan_files` | NO | Same risk as expire_snapshots |

**Schedule compaction freely. Schedule `expire_snapshots` in a 30-minute window at your lowest-traffic time.** For your use case (customers in multiple time zones, 10-15 minute queries), pick a 2-3 AM slot in your primary time zone and accept that occasional queries will need to be retried if they happen to run during that window. Add retry logic at the application layer for Trino queries that fail with file-not-found errors.
