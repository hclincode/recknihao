# Answer to Q1: Iceberg Manifest Cleanup and Slow Query Planning on Trino 467 (Iter 325)

## What manifest files are and why they slow query planning

A **manifest file** is Iceberg metadata that lists which Parquet data files belong to a snapshot, along with per-column min/max statistics for each file. Think of it as a detailed index. Every time your ingestion job writes data, a new manifest file is created to catalog those writes.

**Why they slow down query planning instead of data reading:** When Trino prepares to execute a query, it must read *all* the manifest files to build a plan — before any actual data is touched. This is where partition pruning happens: Trino examines the min/max statistics in the manifests to decide which data files can be skipped. On a table with 50,000 accumulated manifest files (which is common after months of streaming writes), Trino must deserialize and scan all 50,000 before it can tell your query which data to read. Even though each manifest is small, the sheer number makes this phase take 10–30 seconds before your query even begins. This is purely a metadata overhead — it has nothing to do with data file count or table size.

Concrete example: on a table with 50,000 manifests, "planning the query" can take 30+ seconds before any data is read. After `rewrite_manifests`, that drops to under 1 second.

## Why `optimize_manifests` fails on Trino 467

The `optimize_manifests` procedure — `ALTER TABLE iceberg.analytics.events EXECUTE optimize_manifests` — was added to Trino in version **470 (released February 2025)**. You are running Trino 467, which does not include this procedure. Attempting it fails with "procedure not found" because the procedure literally does not exist in your version.

This is a version mismatch, not a bug or misconfiguration. The Iceberg library supports `rewrite_manifests` across all versions, but Trino only exposed it as a native `EXECUTE` command starting in 470.

## What you should actually run on Trino 467

### Option 1: Run from Spark (correct for Trino 467)

Because `optimize_manifests` is not available in Trino 467, run `rewrite_manifests` from Spark:

```sql
-- Spark SQL only — run to compact manifest files on Trino 467
CALL iceberg.system.rewrite_manifests(table => 'analytics.events');
```

This rewrites many small manifests into fewer larger ones, sorted by partition value so Trino's partition-pruning logic works faster. After this runs, query planning latency typically drops from 10–30 seconds to under 1 second.

**How to run it:**
- Via `spark-sql` CLI: `spark-sql -e "CALL iceberg.system.rewrite_manifests(table => 'analytics.events');"`
- Or as a scheduled Spark batch job (nightly CronJob or Airflow task)

**When to schedule it:** Run this **weekly**, paired with your snapshot expiry job. Both are metadata-only operations that don't require data movement. Schedule during off-peak hours when ingestion is paused.

### Option 2: Upgrade to Trino 470+ (longer-term)

After upgrading, you can use the native Trino form:

```sql
-- Trino 470+ only — NOT available on Trino 467
ALTER TABLE iceberg.analytics.events EXECUTE optimize_manifests;
```

In the meantime, use Spark (Option 1).

## Complete maintenance sequence for your slow-query problem

The manifest slowness is usually a symptom of deferred maintenance. Run these four operations in order to recover, then schedule them weekly:

```sql
-- Step 1: Compact small data files (Trino)
ALTER TABLE iceberg.analytics.events EXECUTE optimize(file_size_threshold => '128MB');

-- Step 2: Expire old snapshots (Trino)
ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '30d');

-- Step 3: Remove orphan files (Trino)
ALTER TABLE iceberg.analytics.events EXECUTE remove_orphan_files(retention_threshold => '7d');

-- Step 4: Rewrite manifests — MUST run from Spark on Trino 467
CALL iceberg.system.rewrite_manifests(table => 'analytics.events');
```

**Why this order matters:**
1. Compaction creates new large files and orphans the old small ones.
2. Snapshot expiry releases orphaned files from protection by old snapshots.
3. Orphan cleanup sweeps any files that escaped expiry (from failed writes, etc.).
4. Manifest rewrite compacts the metadata, giving you the query-planning speedup.

After this runs, schedule these four steps weekly to prevent the slowdown from recurring.

## Critical caveat: the 7-day retention floor on Trino 467

Trino 467 enforces a **minimum retention of 7 days** for both `expire_snapshots` and `remove_orphan_files`. Passing `retention_threshold => '3d'` or anything shorter is rejected with an error. For routine weekly maintenance (expiring data 30+ days old), this is fine. For urgent GDPR right-to-erasure purges that need sub-7-day deletion, run `expire_snapshots` from Spark instead — Spark does not enforce this floor.

## Summary

| Action | Where to run on Trino 467 |
|---|---|
| `optimize` (compact data files) | Trino |
| `expire_snapshots` (basic, ≥7d) | Trino |
| `remove_orphan_files` (≥7d) | Trino |
| `rewrite_manifests` / `optimize_manifests` | Spark only (Trino 470+ needed for native) |
| `expire_snapshots` with `retain_last` | Spark only (Trino 479+ needed) |

**Immediate fix:** `CALL iceberg.system.rewrite_manifests(table => 'analytics.events')` from Spark. One-time recovery, takes minutes. Then schedule all four steps weekly.
