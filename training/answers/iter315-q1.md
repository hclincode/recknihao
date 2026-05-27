# Answer to Q1: Storage Sizing and Growth Estimation for Lakehouse Migration (Iter 315)

Your question hits the core challenge of moving from Postgres to a columnar lakehouse: your baseline number is misleading. The good news is that Iceberg will almost certainly be **smaller** than 140 GB, but you need the right math to figure out by how much—and to plan growth correctly.

## Why 140 GB in Postgres is not your starting number

Here's the critical insight: `pg_total_relation_size(events)` includes a lot of things that don't transfer to Iceberg:

1. **Indexes** — typically 30–50% of a Postgres table's on-disk size. Parquet doesn't use indexes; it uses columnar stats and partition pruning instead. Gone on day one.
2. **Bloat and dead tuples** — rows deleted or updated by your application that VACUUM hasn't reclaimed. This typically inflates the heap by 30–50% on a live OLTP database.
3. **Page fragmentation** — free space left by autovacuum within heap pages.

When you run this diagnostic query in Postgres, you'll separate signal from noise:

```sql
SELECT
  relname AS table_name,
  pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
  pg_size_pretty(pg_indexes_size(relid)) AS index_size,
  pg_size_pretty(pg_total_relation_size(relid) - pg_indexes_size(relid)) AS row_data_size
FROM pg_catalog.pg_statio_user_tables
ORDER BY pg_total_relation_size(relid) DESC;
```

For a 140 GB `events` table, expect roughly:
- 30–40% is indexes → remove.
- The remaining 84–98 GB includes ~30–50% bloat → divide by 1.3 to 1.5.

That gives you roughly **60–75 GB of actual row data** that will migrate.

## Parquet compression (why it's magic, and how much you get)

Once Iceberg writes your data as Parquet, compression kicks in. Typical SaaS event data (UUIDs, timestamps, event names, plan types) compresses at **5–10x**—sometimes higher. Why?

- **Low-cardinality strings** (event_name, plan_type, country): 10–50x compression via dictionary encoding — each distinct value is stored once, then rows reference it by a tiny 1-byte code.
- **Timestamps**: 10–20x via delta encoding — you're storing differences between adjacent sorted timestamps, not full values.
- **Booleans**: 50–100x.
- **UUIDs and high-cardinality strings**: 1.5–2x only (patterns are hard to compress).

For a typical event table with a mix of these, **7x compression is a reasonable baseline estimate**.

## The two-step sizing calculation

**Step 1:** Adjust your Postgres baseline.

```
Starting point: 140 GB Postgres total size
- Indexes (assume 30% of total): × 0.70 = 98 GB
÷ Bloat factor (assume 1.3): ÷ 1.3 = ~75 GB actual row data
```

**Step 2:** Apply Parquet compression.

```
75 GB actual rows ÷ 7x compression = ~11 GB on MinIO
```

If your `events` table has mostly low-cardinality columns (event names, a few plan types, a handful of regions), compression could be as good as 10x → ~7.5 GB. If it's JSON-heavy with UUIDs, more like 5x → ~15 GB. The range is **7–15 GB in the lakehouse for a 140 GB Postgres table**.

**Important:** This is dramatically different from the naïve calculation of "140 GB ÷ 5–10x compression = 14–28 GB" that ignores indexes and bloat.

## Fallback: measure before you commit

If you want certainty instead of estimates, export a representative sample of 100,000 rows to Parquet and measure:

```python
# Spark job — export a sample
df = spark.read.jdbc(url=PG_URL, table="(SELECT * FROM events LIMIT 100000) t", properties=PG_PROPS)
df.write.parquet("s3a://lakehouse/sizing-sample/events/")
# Then check actual bytes on MinIO and divide by row count to get real compression ratio
```

Run this first and validate your estimate against reality.

## Planning for 12-month growth

You said you're adding 20–30 new customers, pushing event volume up 40%. Here's the growth math:

**Today:** ~11 GB (from the calculation above).

**In 12 months with 40% growth:**
```
11 GB × 1.40 = 15.4 GB of raw event data
```

But there's another wrinkle: **snapshot accumulation**. When you run Iceberg compaction jobs (merging small Parquet files into larger ones), the old files don't disappear immediately—snapshots still reference them until you run `expire_snapshots` to clean them up. Without scheduled expiry, a table can balloon to 2–3x its logical size in old snapshots.

**With proper snapshot management** (expire snapshots older than 30 days):
```
15.4 GB actual data + ~20% buffer for active snapshots during compaction = ~18–19 GB
```

**Without snapshot expiry** (bad, but it happens):
```
15.4 GB × 2.5 = ~38 GB
```

## MinIO disk sizing recommendation

Use this formula:

```
Year-1 projected size: 15–20 GB (events table after growth)
× 1.5 (headroom for unexpected growth and concurrent snapshot overlap)
+ 20% (filesystem fragmentation and OS overhead)
= target disk size
```

For your case: ~20 GB × 1.5 × 1.20 = ~36 GB usable. A single MinIO node with a few 1 TB drives is sufficient for years of growth.

**MinIO erasure coding note:** MinIO typically uses EC:4 (4 parity drives per 8-drive set), giving ~50% storage efficiency. Plan 2× the usable size in raw disk.

## The practical gotchas

1. **Schedule `expire_snapshots` from day one.** Set a nightly job to expire snapshots older than 30 days. Without this, storage grows silently from old snapshot files Iceberg keeps for time-travel.

2. **Pair compaction with expiry.** After you run nightly `rewrite_data_files` to merge small Parquet files, follow up with `expire_snapshots` so old files are actually cleaned up.

3. **Monitor with the `$files` metadata table.** Once data is in Iceberg, query this to get real numbers:

   ```sql
   SELECT
     SUM(file_size_in_bytes) / 1024 / 1024 / 1024 AS size_gb,
     SUM(record_count) AS total_rows,
     SUM(file_size_in_bytes) * 1.0 / SUM(record_count) AS bytes_per_row
   FROM iceberg.analytics."events$files";
   ```

4. **Consider tiered retention.** Many SaaS teams keep raw events for 18 months, then keep only pre-aggregated rollups indefinitely. That choice alone can cut long-term growth by 40–60%.

## The numbers for your decision

- **Day 1:** ~11 GB (your current 140 GB Postgres table in Iceberg).
- **Year 1 with 40% growth:** ~15–20 GB.
- **MinIO hardware:** A single 4-disk MinIO node (4 TB drives = ~8 TB raw, ~4 TB usable after EC:4) is sufficient for most SaaS lakehouses for 5+ years.

Go run that diagnostic query on your Postgres instance, export the sample, and validate the compression ratio. That 5-minute effort will give you a number you can actually trust.
