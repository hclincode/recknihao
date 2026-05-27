# Iter46 Q2 Answer — Iceberg partition evolution gotcha

**Question**: Six months ago we set up our events table partitioned only by `day(occurred_at)`. A few weeks ago I ran `ALTER TABLE iceberg.analytics.events SET PROPERTIES partitioning = ARRAY['day(occurred_at)', 'tenant_id']` to add tenant_id partitioning. But our dashboards that query a single tenant's data for the last 90 days are still just as slow as before — Trino is still opening thousands of files. I thought adding tenant partitioning would make per-tenant queries faster. What's going on?

---

## The problem you're experiencing

You added `tenant_id` to your Iceberg partition spec a few weeks ago, but your 90-day per-tenant queries are still opening thousands of files. This feels like partitioning should have worked — and it will, but only for the data written *after* the ALTER TABLE command.

## Why old data stays slow: partition spec changes don't rewrite history

When you ran:

```sql
ALTER TABLE iceberg.analytics.events
SET PROPERTIES partitioning = ARRAY['day(occurred_at)', 'tenant_id'];
```

Iceberg changed the partition spec for **new writes only**. Everything written before that command stays in the old partition layout.

**What your table looks like right now:**

| Data age | Partition spec | What queries can prune | Reality |
|---|---|---|---|
| Last few weeks (written after ALTER) | `[day(occurred_at), tenant_id]` | Tenant queries prune to tenant_id's files — fast | Fast ✓ |
| Last ~90 days (written before ALTER) | `[day(occurred_at)]` only | Can't prune by tenant_id; must open all files for those days | Slow ✗ |

When you run "show me the last 90 days for tenant X," Trino:
1. Prunes the newest data by tenant (works).
2. Opens **every single day-partition** for the older data without filtering by tenant, because the old files don't have tenant information encoded in their partition structure.

That is why you still see thousands of files. The newest data is fast; the old data is untouched.

## The fix: rewrite historical data under the new partition spec

You need to physically reorganize the old files so they also use the new partition spec. Use Iceberg's `rewrite_data_files` procedure (run **once**, not on a schedule):

```sql
-- Run in Spark SQL via spark-submit (NOT in Trino)
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.events',
  options => map(
    'target-file-size-bytes', '268435456',  -- 256 MB
    'min-input-files',        '1'           -- rewrite even single-file partitions
  )
);
```

This reads all your old Parquet files and rewrites them under the new `[day(occurred_at), tenant_id]` partition structure. When it finishes, **every file in the table** — including the six months of history — can be pruned by tenant_id.

## Why Spark, not Trino?

The `CALL iceberg.system.*` procedures are Spark SQL features that don't exist in Trino. You must submit this via `spark-submit` or a Spark SQL shell, not the Trino query console.

## Scheduling and storage impact

**Timing:** Rewriting six months of data takes 30–90 minutes depending on your Spark cluster size. **Schedule it during a maintenance window when ingestion is paused** — the rewrite and new writes both need to commit to the table, and they will conflict. Standard pattern: ingestion at 2 AM, rewrite at 4 AM.

**Storage:** MinIO usage will **temporarily spike to ~2x your table size** while old and new files both exist. After rewrite, run your normal maintenance procedures (`expire_snapshots` and `remove_orphan_files`) to clean up the old files and reclaim storage.

## After the rewrite

Your next 90-day per-tenant query should touch only ~90 files (one per day × 90 days) instead of thousands. The partition pruning will work for both old and new data.

---

## Key takeaway

`ALTER TABLE ... SET PROPERTIES partitioning` is a low-cost way to evolve your schema, but **it only applies to new writes**. Partition evolution is one of Iceberg's superpowers — you can start simple and add partitioning later without rewriting everything upfront. But when you do add a partition column, you must run `rewrite_data_files` once to migrate the historical data, or old queries stay slow while new data zooms.
