# Iter130 Q2 — Answer

**Question**: When we first set up our main events table in Iceberg, we partitioned it by month because that felt reasonable at the time. Now the table has grown a lot and we're seeing that queries filtering by day are still scanning way more data than we'd expect — basically the whole month's worth of files even when someone only wants a single day. We want to switch to daily partitioning, but I'm nervous about changing something that fundamental on a table that's already in production with hundreds of millions of rows. Is it even possible to change the partition setup after the fact? And what happens to all the old data that was written under the monthly partitions — does it get rewritten automatically, or does it just sit there and cause problems?

---

## Partition Evolution: Yes, You Can Change It — But Old Data Stays Slow Until You Rewrite It

Yes, you can absolutely change the partition setup after the fact. This is called **partition evolution**, and it's one of Iceberg's major advantages over Hive-style partitioning. But there's a critical caveat that catches most teams: **changing the partition spec only affects new writes — your historical data stays slow until you explicitly rewrite it.**

---

## What Partition Evolution Does (and Doesn't Do)

When you run this:

```sql
-- Trino syntax: switch from monthly to daily partitioning
ALTER TABLE iceberg.analytics.main_events
SET PROPERTIES partitioning = ARRAY['day(occurred_at)', 'tenant_id'];
```

Iceberg does two things:
1. **Updates the partition spec for all future writes** — they land in daily partitions.
2. **Leaves existing data exactly where it is** — files written under the old monthly spec stay in their monthly partition directories on MinIO.

After this ALTER, your table has a **mixed partition spec**:
- Files written before: still partitioned by `month(occurred_at)`.
- Files written after: partitioned by `day(occurred_at)`.

Queries return correct results — Iceberg reads from both specs transparently. **But your old data is still slow.** If 95% of your table was written before the ALTER, 95% of your query I/O gets no pruning benefit from the new daily partition. This is exactly the problem you're seeing.

---

## The Fix: Rewrite Historical Data Under the New Spec

To actually migrate existing data, use `rewrite_data_files` — a Spark procedure that re-reads old files and writes them under the new partition spec:

```sql
-- Step 1: Change the spec for new writes (run from Trino)
ALTER TABLE iceberg.analytics.main_events
SET PROPERTIES partitioning = ARRAY['day(occurred_at)', 'tenant_id'];

-- Step 2: Rewrite all existing data under the new spec (run from Spark SQL)
-- This is expensive — schedule during low traffic.
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.main_events',
  options => map(
    'target-file-size-bytes', '268435456',  -- 256 MB
    'min-input-files',        '1'           -- rewrite even single-file partitions
  )
);

-- Step 3: Monitor progress (Trino or Spark)
-- spec_id=0 = original monthly spec, spec_id=1 = new daily spec
-- When spec_id=0 count reaches 0, rewrite is complete
SELECT spec_id, COUNT(*) AS file_count
FROM iceberg.analytics."main_events$files"
GROUP BY spec_id
ORDER BY spec_id;

-- Step 4: Expire old snapshots to reclaim MinIO storage
-- After rewrite: run from Spark (no 7-day floor):
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.main_events',
  older_than  => current_timestamp() - INTERVAL '7' DAY,
  retain_last => 5
);
-- Or from Trino (7-day floor enforced):
ALTER TABLE iceberg.analytics.main_events
EXECUTE expire_snapshots(retention_threshold => '7d');
```

**Why Step 4 is critical:** `rewrite_data_files` writes new daily-partitioned Parquet files but leaves the old monthly-partitioned files in MinIO because old snapshots still reference them. You must expire those old snapshots to make the old files eligible for deletion.

---

## What Happens to Your Hundreds of Millions of Historical Rows

1. **Stay on MinIO in monthly partition directories** — until `rewrite_data_files` runs.
2. **Get re-read by the rewrite**, sorted by the new spec, and written as new Parquet files in daily-partition directories.
3. **Remain queryable throughout** — snapshot isolation means readers see a consistent view while the rewrite is in flight.
4. **Become unreferenced** after the rewrite completes (the new snapshot points at daily files; old snapshot still points at monthly files).
5. **Get physically deleted from MinIO** only after `expire_snapshots`.

**Temporary storage spike:** Between Step 2 and Step 4, MinIO usage temporarily grows to roughly **2x the table size** (old monthly files plus new daily files). This is normal. After `expire_snapshots`, storage returns to normal.

---

## Timing and Cost

Rewriting on a typical on-prem stack (Spark + Iceberg 1.5.2 + MinIO):

| Table size | Rewrite time (approximate) |
|---|---|
| ~100 GB | 10–20 minutes |
| ~1 TB | 30–90 minutes |
| ~10 TB | Several hours |

**Do not run this during your ingestion window.** Compaction and new writes contend on commits. Standard pattern:
- Ingestion runs nightly at 2 AM.
- Partition rewrite runs at 4–5 AM (after ingestion finishes).
- This is a one-time operation, not recurring.

---

## Concrete Plan for Your Table

**Friday 5 PM (low traffic):**
```sql
-- Announce new spec — new writes immediately go to daily partitions
ALTER TABLE iceberg.analytics.main_events
SET PROPERTIES partitioning = ARRAY['day(occurred_at)', 'tenant_id'];
```

Weekend ingestion (Saturday–Sunday) writes new data in daily partitions.

**Monday 4 AM (after ingestion window):**
```sql
-- Rewrite all historical data (Spark job, ~1.5–2 hours for 600M rows)
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.main_events',
  options => map('target-file-size-bytes', '268435456', 'min-input-files', '1')
);

-- Monitor: wait for spec_id=0 count to reach 0
SELECT spec_id, COUNT(*) FROM iceberg.analytics."main_events$files" GROUP BY spec_id;

-- After rewrite complete: expire old snapshots
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.main_events',
  older_than  => current_timestamp() - INTERVAL '7' DAY,
  retain_last => 5
);
```

**By Monday noon:** Rewrite done, old files gone, MinIO storage normal, daily-partitioned queries running 10–30x faster.

---

## Verify It Worked

```sql
SELECT COUNT(*)
FROM iceberg.analytics.main_events
WHERE occurred_at >= TIMESTAMP '2026-05-25 00:00:00'
  AND occurred_at <  TIMESTAMP '2026-05-26 00:00:00';
```

Check `physical_input_bytes` in the Trino UI or `system.runtime.queries`. You should see a ~30x reduction in data scanned (one day's files instead of a whole month's).

If scans are still large, the rewrite may not have finished — recheck the `$files` spec_id counts.

---

## Summary

The three-step process is:
1. **ALTER TABLE** — unlocks pruning for new writes (instant, safe, do immediately).
2. **`rewrite_data_files`** — physically moves historical data to daily partitions (expensive, one-time, schedule off-hours).
3. **`expire_snapshots`** — frees old files from MinIO (necessary for storage reclaim).

The whole operation is snapshot-isolated — queries run throughout. Plan for a 1–3 hour maintenance window depending on table size, and schedule outside your ingestion window.
