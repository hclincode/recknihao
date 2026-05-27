# Iter73 Q1 — Answer

**Question**: We've had an Iceberg table partitioned by day for about 14 months now. We're building hourly dashboards and each query ends up scanning the whole day's partition even though it only needs the last hour. I want to switch from daily to hourly partitioning. But I'm nervous about what happens to the existing data. Do old files get moved or rewritten automatically? Does Iceberg handle queries spanning old day-partitions and new hour-partitions gracefully? Do I have to drop and recreate the table?

---

## Answer

The short answer: Iceberg handles this gracefully without rewriting old files automatically, but you need to take a deliberate two-step action if you want historical queries to also benefit from the new spec.

### (a) Do old files get moved or rewritten automatically?

**No, not automatically.** When you run:

```sql
ALTER TABLE iceberg.analytics.events
SET PROPERTIES partitioning = ARRAY['hour(occurred_at)'];
```

Iceberg updates the **partition spec for future writes only**. Your 14 months of existing data stays exactly where it is — no rewrite, no file movement. Those old files still carry their original `day(occurred_at)` partition metadata. This is called **partition evolution**, and it's one of Iceberg's core features.

**The catch:** those old day-partitioned files don't automatically get faster under the new spec. If you run a query filtering by a specific hour within a day, Iceberg cannot prune based on hour boundaries for the old files — it only knows they're partitioned by day. Trino reads the entire day's partition for historical data, even though you only needed one hour.

To actually migrate old data to the new spec, you run a one-time rewrite after the ALTER:

```sql
-- Step 1: change the spec for new writes (Trino or Spark SQL)
ALTER TABLE iceberg.analytics.events
SET PROPERTIES partitioning = ARRAY['hour(occurred_at)'];

-- Step 2: rewrite all existing files under the new spec (Spark SQL only)
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.events',
  options => map(
    'target-file-size-bytes', '268435456',
    'min-input-files',        '1'
  )
);
```

After this completes, your entire table — old and new data — follows the hourly spec and partition pruning works correctly across the full 14-month history.

### (b) Do queries spanning old and new partitions work correctly?

**Yes, completely.** This is one of Iceberg's core guarantees. After the ALTER but before the rewrite, your table has:
- Old files: `day(occurred_at)` spec (e.g., `day=2025-03-15`)
- New files: `hour(occurred_at)` spec (e.g., `hour=2026-05-25-10`)

A query like:
```sql
SELECT COUNT(*) FROM iceberg.analytics.events
WHERE occurred_at >= TIMESTAMP '2026-05-01 00:00:00'
  AND occurred_at <  TIMESTAMP '2026-05-31 23:59:59';
```

Trino tracks which partition spec each file was written under (stored in Iceberg metadata). It prunes old day-partitioned files by day, prunes new hour-partitioned files by hour, reads both sets, and merges the results correctly. **Semantics are correct — no duplication, no missing rows.** You just pay a performance cost on old historical data until `rewrite_data_files` completes.

### (c) Do you have to drop and recreate the table?

**No.** Partition evolution is specifically designed to avoid this. The workflow:

1. **Run `ALTER TABLE`** — metadata-only, takes milliseconds, no downtime, no data movement.
2. **New writes immediately use the hourly spec.** Existing queries continue working against both old and new files.
3. **When convenient, run `rewrite_data_files` in Spark** to migrate historical data. This is a background job you can schedule for low-traffic hours.

### Cost and timing for a large table

For 14 months of data, expect the rewrite to take 30 minutes to a few hours depending on table size and Spark cluster resources.

**Storage will temporarily spike (~2× table size)** because new files are written before old ones are deleted. After the rewrite finishes, run the standard maintenance sequence to reclaim space:

```sql
-- Run in Spark after rewrite_data_files completes
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.events',
  older_than  => current_timestamp() - INTERVAL '7' DAY,
  retain_last => 5
);

CALL iceberg.system.remove_orphan_files(
  table      => 'analytics.events',
  older_than => current_timestamp() - INTERVAL '3' DAY
);
```

Only after `expire_snapshots` runs are the old files unreferenced and eligible for actual deletion from MinIO.

### Recommended timeline

1. **Run the ALTER** during business hours (instant, read-safe).
2. **Let new data flow under the hourly spec** for a day or two to verify it works.
3. **Schedule `rewrite_data_files` for a weekend night or low-traffic window** (2–3 hour window).
4. **Run the maintenance jobs the following morning** to free storage.

After the rewrite, hourly dashboards will see a dramatic speedup on historical queries — Trino can prune down to the exact hour needed instead of reading the full day.
