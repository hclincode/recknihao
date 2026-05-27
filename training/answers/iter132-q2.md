# Iter132 Q2 — Answer

**Question**: "Our nightly Spark job that loads the previous day's events into Iceberg has gone from taking 45 minutes to almost 3 hours over the last few months as our data volume grew. We haven't really changed the job — it's basically reading from Postgres via JDBC, doing some light transformations, and writing to Iceberg on MinIO. I don't really know where to start looking. Is this a Spark tuning problem, an Iceberg config problem, a MinIO throughput problem, or something else? What are the most common reasons a job like this slows down, and what knobs do we actually have to turn to get it back under control?"

---

## The 4x Slowdown Is Almost Certainly Iceberg File Accumulation, Not MinIO

When a Spark-JDBC-to-Iceberg job doubles or triples in runtime as data volume grows, the culprit is almost always **Iceberg small-file accumulation**, not Spark tuning or MinIO throughput. Here's how to diagnose it in 15 minutes, then fix each root cause in priority order.

---

## 30-Minute Diagnosis First

Before tuning anything, measure where the time is actually going. Add timing instrumentation to your Spark job:

```python
import time

# Time each stage separately
t0 = time.time()
df = spark.read \
    .format("jdbc") \
    .option("url", "jdbc:postgresql://pg-replica:5432/app_db") \
    .option("dbtable", "(SELECT * FROM events WHERE created_at >= '2026-05-25') AS q") \
    .option("fetchsize", "10000") \
    .load()
t1 = time.time()

df_transformed = df.withColumn(...)  # your light transformations
t2 = time.time()

df_transformed.writeTo("iceberg.analytics.events").append()
t3 = time.time()

print(f"JDBC read: {t1-t0:.1f}s | Transform: {t2-t1:.1f}s | Iceberg write: {t3-t2:.1f}s")
```

This tells you in one run whether you have a **read problem** (JDBC is slow), a **write problem** (Iceberg commit is slow), or a **transform problem** (unlikely given "light transformations").

**Typical pattern for the 4x slowdown you're describing:** the Iceberg write phase is 80–90% of total runtime and grows quadratically with table age. If your write time is >> your read time, you have a file accumulation problem.

---

## Root Cause 1 (Most Common): Iceberg Small-File Accumulation

Every nightly run appends new Parquet files to the Iceberg table. If your job writes 50 small files per night and you've been running for 90 days, you now have 4,500 files. Iceberg must read **all manifest files** to plan every query and every commit — planning overhead grows with file count even when the actual data being read is small.

### Diagnose: check your current file count

```sql
-- Run from Trino or Spark SQL
SELECT
  COUNT(*)                                      AS total_files,
  ROUND(AVG(file_size_in_bytes)/1e6, 1)        AS avg_file_mb,
  ROUND(SUM(file_size_in_bytes)/1e9, 2)        AS total_gb
FROM iceberg.analytics."events$files";
```

**Healthy:** 50–200 files, avg size 128–512 MB.
**Unhealthy:** 1,000+ files, avg size < 32 MB. This is a compaction emergency.

Also check snapshot accumulation:

```sql
SELECT COUNT(*) AS snapshot_count FROM iceberg.analytics."events$snapshots";
```

If snapshot count > 100 and each snapshot's manifest file is several MB, every commit is reading hundreds of MB of metadata before writing a single byte of data.

### Fix 1a: Run compaction immediately (one-time catch-up)

```python
# Run via spark-submit — this is the single highest-ROI action
spark.sql("""
    CALL iceberg.system.rewrite_data_files(
        table   => 'analytics.events',
        options => map(
            'target-file-size-bytes', '268435456',   -- 256 MB target
            'max-concurrent-file-group-rewrites', '4'
        )
    )
""")
```

After this runs, your `events$files` table should show 10–50 well-sized files instead of thousands of tiny ones. Commit overhead drops dramatically.

### Fix 1b: Expire old snapshots (one-time catch-up)

```sql
-- Run from Spark (no minimum retention floor)
CALL iceberg.system.expire_snapshots(
  table        => 'analytics.events',
  older_than   => current_timestamp() - INTERVAL '7' DAY,
  retain_last  => 5
);
```

> **Note:** Trino enforces a 7-day minimum retention floor on `expire_snapshots`. For urgency, use Spark which has no floor.

### Fix 1c: Add nightly compaction to your pipeline (permanent fix)

Add a second Spark job that runs after your ingestion job finishes:

```python
# Run nightly at 3 AM after ingestion (which runs at 2 AM)
spark.sql("""
    CALL iceberg.system.rewrite_data_files(
        table   => 'analytics.events',
        options => map(
            'target-file-size-bytes', '268435456'
        )
    )
""")

spark.sql("""
    CALL iceberg.system.expire_snapshots(
        table        => 'analytics.events',
        older_than   => current_timestamp() - INTERVAL '7' DAY,
        retain_last  => 5
    )
""")
```

**Important:** Do NOT use `rewrite-all=true` in your nightly compaction job. That flag forces rewriting every file regardless of size, which defeats the purpose of compaction (skip well-sized files). Use `rewrite-all=true` only for post-partition-evolution migration. The default bin-pack strategy is what you want for ongoing compaction — it skips files that are already well-sized.

---

## Root Cause 2: JDBC Read Tuning — Missing Index or Bad Fetch Size

If your timing shows the **read** phase is slow, there are two common causes.

### Diagnose: check for a watermark index

Your nightly job reads "yesterday's events" — meaning it filters on a timestamp column (e.g., `created_at`). If that column doesn't have an index on the Postgres replica:

```sql
-- Run on the Postgres replica
SELECT indexname, indexdef
FROM pg_indexes
WHERE tablename = 'events';
```

If `created_at` doesn't appear in any index, your JDBC read is doing a full table scan of the entire `events` table every night. As the table grows, the read time grows linearly.

```sql
-- Fix: add the index (on the replica, or replicated from primary)
CREATE INDEX CONCURRENTLY idx_events_created_at ON events (created_at);
```

### Diagnose and fix: JDBC fetch size

The default JDBC `fetchsize` in most drivers is 0 or very small (Postgres default: all rows at once with no server-side cursor, which can OOM; or 1 row at a time with explicit cursor). Set it explicitly:

```python
df = spark.read \
    .format("jdbc") \
    .option("url", "jdbc:postgresql://pg-replica:5432/app_db") \
    .option("dbtable", "(SELECT * FROM events WHERE created_at >= current_date - INTERVAL '1 day') AS q") \
    .option("fetchsize", "10000") \         # rows per network round-trip
    .option("numPartitions", "8") \         # parallel JDBC readers
    .option("partitionColumn", "id") \      # split by row ID for parallelism
    .option("lowerBound", "1") \
    .option("upperBound", "999999999") \
    .load()
```

**`numPartitions`** controls how many parallel JDBC connections Spark opens to Postgres. Don't set this above your Postgres `max_connections` budget for the replica — 8–16 is typically safe for a dedicated replica.

### Check replica lag

If you're reading from a Postgres replica, replication lag means your nightly job sees data that's behind the primary. If the lag exceeded your job's lookback window, rows were silently missed. Check lag before each run:

```sql
-- On the replica
SELECT EXTRACT(EPOCH FROM (NOW() - pg_last_xact_replay_timestamp())) AS lag_seconds;
```

If lag > 300 seconds, delay the job or read from the primary.

---

## Root Cause 3: Spark Writer Partitioning — One Task Doing All the Work

If your data has a skewed distribution and Spark's write parallelism is 1 or 2, one task writes all the data sequentially while the rest idle.

### Diagnose: check task parallelism in Spark UI

After your job runs, go to the Spark UI → the write stage → look at task count and duration. If you see 1–2 tasks doing all the work while others finish in milliseconds, you have a write parallelism problem.

### Fix: repartition before write

```python
# Repartition to match your desired Parquet file count
# Rule of thumb: 1 partition per 256 MB of output data
df_transformed \
    .repartition(16)  \       # produces 16 Parquet files
    .writeTo("iceberg.analytics.events") \
    .append()
```

Or repartition by your partition column for better pruning:

```python
df_transformed \
    .repartition("tenant_id") \
    .sortWithinPartitions("occurred_at") \  # improves column pruning at read time
    .writeTo("iceberg.analytics.events") \
    .append()
```

---

## Priority Order: Where to Start

| Root cause | How to diagnose | Time to fix | Expected gain |
|---|---|---|---|
| Small-file accumulation | `SELECT COUNT(*) FROM events$files` | 30 min (one-time compaction) | 3–10x speedup |
| Missing watermark index | `pg_indexes` on replica | 5 min (index creation: 10–30 min) | 2–5x speedup |
| Bad JDBC fetch size | Read stage timing >> write stage | 10 min (config change) | 1.5–2x speedup |
| Write skew | Spark UI task distribution | 10 min (add repartition) | 1.5–3x speedup |

**Start with file count.** If `SELECT COUNT(*) FROM events$files` shows > 500 files, run the one-time compaction before anything else. Nine times out of ten, that single action gets you from 3 hours back under 1 hour.

---

## Permanent Fix: Nightly Pipeline Structure

After tuning, your nightly job schedule should look like:

```
02:00 AM  Ingestion job:  JDBC read → transform → Iceberg write
03:00 AM  Compaction job: rewrite_data_files (nightly, no rewrite-all=true)
03:30 AM  Cleanup job:    expire_snapshots (weekly, retain_last=5, older_than=7d)
```

Keep compaction and ingestion in separate jobs. Running compaction inside the same Spark session as ingestion means compaction is reading files that the ingestion job may still be committing — the commit ordering can produce manifest conflicts.

---

## Summary

Your 4x slowdown is almost certainly Iceberg file accumulation — check `events$files` first. The fix is a one-time compaction run + a permanent nightly compaction job added to your pipeline. If the read phase is slow, check for a missing index on your watermark column and set `fetchsize=10000` in your JDBC options. Both fixes take under an hour to implement and should bring your job back to under 60 minutes.
