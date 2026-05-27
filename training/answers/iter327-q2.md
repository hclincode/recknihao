# Answer to Q2: Diagnosing Iceberg manifest bloat before running rewrite_manifests (Iter 327)

## What manifest bloat is

Iceberg stores **manifest files** — internal metadata files that list which data files belong to each snapshot with per-column min/max statistics. Every write creates a new manifest. After weeks of streaming writes or frequent micro-batches, you accumulate hundreds or thousands of small manifests. Trino must read all of them during query planning to decide which data files to access — this "plan time" balloons from under 1 second to 10+ seconds before any actual data is read.

## How to diagnose it: the `$manifests` metadata table

In Trino 467, every Iceberg table exposes internal metadata via `$`-suffixed views. Query the manifest count directly:

```sql
SELECT COUNT(*) AS manifest_count
FROM iceberg.analytics."events$manifests";
```

This is your baseline diagnostic — one number tells you the state.

For more detail:

```sql
SELECT
  COUNT(*) AS manifest_count,
  SUM(manifest_length) / 1024 / 1024 AS total_manifest_size_mb,
  ROUND(AVG(added_data_files_count)) AS avg_files_per_manifest,
  MAX(added_data_files_count) AS max_files_per_manifest
FROM iceberg.analytics."events$manifests";
```

## What the count means: thresholds and rule of thumb

| Manifest count | Status | Decision |
|---|---|---|
| < 10 | Healthy | No action needed |
| 10–50 | Growing but okay | Monitor; watch if planning latency creeps past 2s |
| 50–200 | Watch closely | If planning latency is 5+ seconds, `rewrite_manifests` is worth running |
| 200+ | Almost certainly too many | Run `rewrite_manifests` — planning is likely 10+ seconds |

**Why these thresholds:** Each manifest adds latency to planning. With < 10, cost is negligible. By 200+, the coordinator is spending most of its planning time opening manifest files instead of pruning data.

## What columns in `$manifests` tell you

| Column | What it reveals |
|---|---|
| `manifest_length` | Size in bytes — sum to understand total metadata overhead Trino reads per query |
| `partition_spec_id` | If you see multiple IDs, the partition spec evolved; multiple specs coexisting is normal but adds planner work |
| `added_data_files_count` | Files per write — if avg is < 5, you're writing small micro-batches; manifests will accumulate fast |
| `existing_data_files_count` | Files inherited from prior snapshots — grows with each incremental write |
| `deleted_data_files_count` | Files removed — non-zero means deletes or compaction have run |

If `avg_files_per_manifest < 5`, you're running a streaming/micro-batch pattern and manifests are accumulating faster than typical batch jobs.

## The relationship between small files and manifests

Every write creates a manifest. After two weeks of streaming at 12 micro-batches/day: `12 × 14 = 168 manifests`. Each manifest is small (~30 KB), but query planning must open all 168.

Compaction (`rewrite_data_files`) reduces data file count but **leaves the manifest history behind**. Only `rewrite_manifests` actually consolidates manifests. A table can have 50,000 small data files but only 500 manifests (if files were written in large batches), or 2,000 manifests with only 8,000 data files (if many incremental writes ran before compaction).

## When to run vs skip `rewrite_manifests`

**Run it when:**
- Query planning is slow (5+ seconds for a simple `SELECT COUNT(*)`) and manifest count is 50+
- You've already run compaction but planning is still slow — this points at manifests, not file count
- Manifest count grows by 10+ per day (streaming ingestion pattern)

**Skip it when:**
- Manifest count is < 10 — the table is healthy
- Query planning is fast even with a higher count — some well-partitioned tables tolerate 100+ manifests
- Compaction is currently running — wait for it to finish, then re-measure

## Before/after measurement

```sql
-- Capture BEFORE running rewrite_manifests:
SELECT
  COUNT(*) AS manifest_count,
  SUM(manifest_length) / 1024 / 1024 AS total_manifest_size_mb
FROM iceberg.analytics."events$manifests";
```

Then run the fix from **Spark** (not Trino — `optimize_manifests` requires Trino 470+):

```sql
-- Spark SQL only on Trino 467:
CALL iceberg.system.rewrite_manifests(table => 'analytics.events');
```

Then verify:

```sql
-- Should show dramatically lower count (often 80–95% reduction):
SELECT COUNT(*) AS manifest_count
FROM iceberg.analytics."events$manifests";
```

A table with 200 manifests typically drops to 5–10 after rewrite. Query planning drops proportionally — 15s → 2–3s is common.

## Complete diagnostic sequence

```sql
-- Step 1: Check manifest count
SELECT COUNT(*) FROM iceberg.analytics."events$manifests";

-- Step 2: Understand the ingestion pattern
SELECT
  COUNT(*) AS manifest_count,
  ROUND(AVG(added_data_files_count)) AS avg_files_per_manifest,
  SUM(manifest_length) / 1024 / 1024 AS total_metadata_mb
FROM iceberg.analytics."events$manifests";

-- Step 3: If count > 50, run from Spark:
-- CALL iceberg.system.rewrite_manifests(table => 'analytics.events');

-- Step 4: Verify after
SELECT COUNT(*) FROM iceberg.analytics."events$manifests";
```

If planning is still slow after `rewrite_manifests`, the bottleneck is not manifests — check partition design (too many partitions) or query predicate pushdown effectiveness.
