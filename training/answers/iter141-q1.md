# Iter141 Q1 — Answer

**Question**: "We had a Trino query running against an Iceberg table in MinIO that was consistently finishing in about 8 seconds. After we added a bunch of new customers last month and the table grew from roughly 50GB to 200GB, the same query now takes 45 seconds. I ran EXPLAIN ANALYZE on it and got back this wall of output about 'splits,' 'pipeline,' 'operators,' and timing numbers at every stage, but I honestly have no idea how to read it or what I'm supposed to look for. Is there a way to make sense of that output — like, what parts actually tell you where the time is going, and once you find the bottleneck, what can you actually do about it?"

---

## How to Read EXPLAIN ANALYZE

`EXPLAIN ANALYZE` executes your query for real and collects timing telemetry at every stage. The output is a tree of operators — Scan, Filter, Aggregate, Exchange — each showing:

- **Planned numbers**: what the planner expected
- **Actual execution times**: wall time and CPU time at each operator
- **Data volumes**: rows and bytes actually processed

The first thing to look for is the table scan line:

```
TableScan[iceberg:analytics.feature_usage] — Files: 4860, Input: 847000000 rows / 189 GB
```

This single line tells you how many Parquet files Trino opened and how much data it actually read. **This is where your slowdown is hiding.**

---

## What to Look For: The Scan Operator

Jump straight to the `Scan[Iceberg]` or `TableScan` line. Key numbers:

| What | What it means |
|---|---|
| **Files: N** | How many Parquet files Trino opened. If this jumped from ~50 to ~3,000, your problem is file count. |
| **Input: X rows, Y bytes** | Data rows/bytes that passed partition filters. Compare to total table size. |
| **Wall time vs CPU time** | If wall time is 5–10× CPU time: I/O-bound (reading too many files). If close: compute-bound. |

For your specific case — 8s on 50 GB now 45s on 200 GB — if it were just more data you'd expect ~2× slower. The 5× increase suggests files or pruning changed, not just volume.

---

## The Two Common Causes

### Cause A: File count explosion (most likely)

Your 50 GB table had ~200–300 compacted files. After adding customers, you now have 3,000+ small files from frequent micro-batch writes and missed compaction. Each file has 10–50 ms of overhead to open and check statistics. A query that scanned 300 files in 1 second now burns 30+ seconds just on file opens before reading any data.

### Cause B: Partition pruning stopped working

Your `WHERE` clause used to prune the table to a small subset. Something changed — a schema change, a derived expression that no longer maps to the partition spec, or a filter on a non-partition column that was previously clustered.

---

## Diagnose Which Problem You Have

**Step 1: Check files read vs total table size**

```sql
-- Get total table row count
SELECT COUNT(*) FROM iceberg.analytics.feature_usage;

-- Then compare to EXPLAIN ANALYZE "Input: X rows"
EXPLAIN ANALYZE
SELECT tenant_id, COUNT(*) FROM iceberg.analytics.feature_usage
WHERE event_date >= CURRENT_DATE - INTERVAL '90' DAY
GROUP BY tenant_id;
```

| Input rows | Diagnosis |
|---|---|
| ≈ total table rows | Partition pruning broken — fix the WHERE clause |
| Much less than total | Pruning works, but file count is the problem |

**Step 2: Check file count directly**

```sql
SELECT COUNT(*) AS total_files, AVG(file_size_in_bytes) / 1048576.0 AS avg_mb
FROM iceberg.analytics."feature_usage$files";
```

If `avg_mb < 50` or `total_files > 1000` for a 200 GB table, you have a small-file problem.

---

## What "Splits" Are

A split is one Parquet file assigned to one Trino worker task. With 32 worker threads and 3,000 splits, Trino queues them and processes them in batches of 32. File-open overhead compounds: 3,000 files × 20 ms = 60 seconds of overhead before the first row is returned.

More files is not always better. 150 well-sized 256 MB files is faster than 3,000 small files of 10 MB each.

---

## The Fix: Compaction

```python
# Spark SQL — run nightly after ingestion
spark.sql("""
    CALL iceberg.system.rewrite_data_files(
        table   => 'analytics.feature_usage',
        options => map(
            'target-file-size-bytes', '268435456',
            'min-input-files', '5'
        )
    )
""")
```

This merges small files into ~256 MB targets. After compaction, file count drops from 3,000 to ~150–200 and query planning drops from 30+ seconds to under 1 second.

**Trino alternative (ad-hoc, from any Trino session):**

```sql
ALTER TABLE iceberg.analytics.feature_usage
EXECUTE optimize(file_size_threshold => '128MB');
```

**Important**: Compaction alone doesn't free MinIO storage — old small files still exist in older snapshots. Run the full sequence:

```sql
-- 1. Compact (already done above)

-- 2. Expire old snapshots (removes references to old small files)
ALTER TABLE iceberg.analytics.feature_usage
EXECUTE expire_snapshots(retention_threshold => '30d');

-- 3. Remove orphan files from MinIO
ALTER TABLE iceberg.analytics.feature_usage
EXECUTE remove_orphan_files(retention_threshold => '7d');
```

---

## Verify the Fix

```sql
EXPLAIN ANALYZE
SELECT tenant_id, COUNT(*) FROM iceberg.analytics.feature_usage
WHERE event_date >= CURRENT_DATE - INTERVAL '90' DAY
GROUP BY tenant_id;
```

After compaction, look for:
- **Files: N** — dropped from thousands to hundreds? Success.
- **Wall time** — dropped from 45s to 10–12s? Correct.
- **Input bytes** — same (if pruning was already working) or less (if you fixed a pruning bug too).

---

## Prevent Future Regression

Schedule compaction nightly so file count doesn't creep back up:

```python
# Kubernetes CronJob or Airflow DAG at 4 AM
spark.sql("""
    CALL iceberg.system.rewrite_data_files(
        table   => 'analytics.feature_usage',
        options => map('target-file-size-bytes', '268435456', 'min-input-files', '5')
    )
""")
```

The pattern you're experiencing is normal at your growth stage: data volume matters less than how the table is organized. After compaction and regular maintenance, your query will stay fast as the table grows to 500 GB or 1 TB.
