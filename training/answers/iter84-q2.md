# Iter84 Q2 — Answer

**Question**: Changing Iceberg table partitioning from `day(event_time)` to `(day(event_time), tenant_id)` on a live production table with 8 months of data. Zero downtime? Old files rewritten? Query behavior during transition?

---

## Answer

Good news: **you can absolutely change the partitioning on a live Iceberg table without any downtime or data loss.** You don't have to dump and reload.

### Step 1: Flip the partition spec for future writes

```sql
ALTER TABLE iceberg.analytics.user_events
SET PROPERTIES partitioning = ARRAY['day(occurred_at)', 'tenant_id'];
```

This tells Iceberg "from now on, write new data under this partition scheme." It takes a few seconds and causes zero query disruption. **Existing queries keep running.** The change is purely about how *new* writes get organized.

### Step 2: Understand what happens to your 8 months of old data

Here's the critical part that surprises most engineers: **old files do not automatically get rewritten.** The 8 months of data sitting in those `day(occurred_at)`-only partitioned files stays exactly where it is, under the old partition spec. Iceberg supports both at once — it's called **partition evolution**.

What this means concretely: the day after you run the ALTER, you have a split table:

- **8 months of old files:** organized by `day(occurred_at)` only. Each day's directory contains every tenant's data mixed together.
- **New files (going forward):** organized by `day(occurred_at), tenant_id` — separate directories for each tenant within each day.

### Step 3: How Trino handles the mixed layout

When you run `WHERE occurred_at >= '2026-05-01' AND tenant_id = 'acme'`, Trino:

1. **Reads new files correctly:** files written after the ALTER have `tenant_id` in their partition path, so Trino prunes to just acme's files within that date range. Fast.
2. **Reads old files less efficiently:** the old `day(occurred_at)`-only files can't prune by tenant_id. Trino has to open every tenant's files for those days, then apply the `tenant_id = 'acme'` filter at row-read time. Slower, but **correct** — queries return accurate results.

In practical terms: if your old 8-month window is 80% of your total data, that 80% scans at the old efficiency (missing the tenant-id pruning benefit), while the new 20% scans with full two-level pruning. Your overall query speed improves immediately, but not as much as if everything were on the new spec.

### Step 4: Migrate historical data if you want full efficiency everywhere

This is optional but recommended. Once you've let the new spec settle in for a few days, run `rewrite_data_files` to physically reorganize the old data:

```sql
-- Spark SQL only — run via spark-submit or your Spark scheduler (Airflow, etc.)
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.user_events',
  options => map(
    'target-file-size-bytes', '268435456',  -- 256 MB
    'min-input-files',        '1'
  )
);
```

What this does: Spark reads every Parquet file in the table and rewrites it, placing each rewritten file into the new partition structure (`day(occurred_at), tenant_id`). After it finishes, every file in your table — old and new — sits in the two-level directory layout. Now queries on the full 8 months get the full tenant-id pruning benefit.

**Cost:** rewriting 8 months of data takes 30–90 minutes on the production Spark cluster, depending on data volume. The rewrite creates new files temporarily doubling storage until `expire_snapshots` runs (routine weekly maintenance) to clean up the old files.

**Timing:** run during a quiet window (e.g., weekend morning) when writes are paused. If your ingestion stops at midnight and restarts at 8 AM, run the rewrite at 1–2 AM.

### Why this beats a full reload

- **Zero query downtime.** Queries run during the rewrite against whichever snapshot was current when they started.
- **No bulk dump/reload dance.** No exporting to Parquet, recreating the table, re-uploading — just a controlled file reorganization that Iceberg handles atomically.
- **Instant rollback if something goes wrong.** You can roll back to the pre-rewrite snapshot with a single command.

### The gotcha that trips up engineers

`ALTER TABLE ... SET PROPERTIES partitioning = ...` changes the spec for new writes only. It does NOT touch old files. So the day after you run the ALTER, if you check a query's scan size, you might see it hasn't dropped much. That's because the old 8 months of data still can't prune by `tenant_id`. It feels like the ALTER didn't work. It did work — but only for new data. You have to run `rewrite_data_files` separately to get the old data reorganized.

### Summary checklist

1. **Run the ALTER** during your next maintenance window (seconds, no downtime).
2. **Let new writes settle** for a few days under the new spec.
3. **Schedule `rewrite_data_files`** for a quiet weekend morning to reorganize the historical 8 months.
4. **Run `expire_snapshots` afterward** (routine weekly job anyway) to reclaim storage.
5. **Verify** that tenant_id filters now prune efficiently on dates that span both old and new data.

You'll have zero downtime, zero data loss, and full tenant-id partition pruning across your entire table within a day of work spread over a weekend.
