# Iter122 Q2 — Answer

**Question**: We're about 6 months into using Trino and our cloud bill keeps climbing. I honestly have no idea whether we're paying a normal amount for the queries we run or if something is wildly inefficient. Is there a way to figure out which queries are burning the most compute, and are there common mistakes SaaS teams make early on that cause Trino costs to be way higher than they should be?

---

## Diagnosing Your Trino Cost Problem: A Step-by-Step Guide

You're in a tough spot — six months in and the bill keeps climbing. The good news is that on-premises Trino + Iceberg + MinIO doesn't have cloud's per-query surprise pricing model. Your actual marginal query cost is nearly zero (hardware is paid). What you *are* seeing is either **engineering debt piling up** or **queries that are wildly inefficient** — and both are fixable.

---

## Part 1: Identifying Your Most Expensive Queries

Trino doesn't have automatic cost alerts (unlike BigQuery or Snowflake), so you need to build the visibility yourself. The easiest way is to query Trino's own system tables.

### Query Trino's query history

```sql
SELECT
  query_id,
  query,
  state,
  queued_time_ms / 1000.0 AS queued_sec,
  execution_time_ms / 1000.0 AS wall_time_sec,
  cpu_time_ms / 1000.0 AS cpu_time_sec,
  peak_memory_bytes / 1024 / 1024 / 1024 AS peak_memory_gb,
  physical_input_bytes / 1024 / 1024 / 1024 AS input_gb,
  created,
  completed_at
FROM system.runtime.tasks
WHERE completed_at > CURRENT_TIMESTAMP - INTERVAL '7' DAY
ORDER BY physical_input_bytes DESC
LIMIT 50;
```

This shows you the top 50 heaviest queries from the last 7 days, ranked by how much data they read. Focus on the ones with high `input_gb` — those are burning the most cluster time and I/O.

### Find the queries that run most frequently

High frequency × moderate cost = sustained load:

```sql
SELECT
  query,
  COUNT(*) AS run_count,
  AVG(physical_input_bytes / 1024 / 1024 / 1024) AS avg_input_gb,
  MAX(physical_input_bytes / 1024 / 1024 / 1024) AS max_input_gb,
  AVG(execution_time_ms / 1000.0) AS avg_wall_time_sec
FROM system.runtime.tasks
WHERE completed_at > CURRENT_TIMESTAMP - INTERVAL '7' DAY
GROUP BY query
ORDER BY run_count DESC
LIMIT 20;
```

If a single dashboard query runs 100 times per day at 50 GB per run, that's 5 TB of daily I/O for one dashboard. That's expensive, and it's fixable.

---

## Part 2: The Three Biggest Self-Inflicted Cost Explosions

Most SaaS teams on this stack fall into the same three traps. Check each one.

### Trap 1: Missing Partition Pruning (the biggest lever)

This is the single most impactful optimization on Trino + Iceberg. A well-partitioned query might read 1 TB of raw data but only touch 5 GB after partition pruning — that's 200x less compute. A poorly-partitioned query reads everything.

**Diagnose it:**

```sql
-- Check if your fact tables are actually partitioned
SHOW CREATE TABLE iceberg.analytics.your_fact_table;
```

Look for a `partitioning` clause. If there's nothing, **that table is unpartitioned and every query scans it entirely.**

If it is partitioned, run `EXPLAIN` on a typical dashboard query to see the query plan before running it:

```sql
EXPLAIN
SELECT tenant_id, COUNT(*) AS events
FROM iceberg.analytics.feature_usage
WHERE event_date >= CURRENT_DATE - INTERVAL '90' DAY
GROUP BY tenant_id;
```

Look at the **Files** count or table scan estimates. If you're seeing full scans on what should be a pruned query, one of these is the culprit:

1. **The WHERE clause doesn't filter on the partition column** — e.g., you're filtering by `feature_name = 'invite'` but the table is partitioned by `day(event_date)`. The partition pruner can't help.

2. **The partition column is wrapped in a function** — e.g., `WHERE DATE(event_time) = CURRENT_DATE` instead of `WHERE event_date = CURRENT_DATE`. Some functions break pruning.

3. **You added a partition column later via partition evolution and never rewrote the old data** — new files are partitioned correctly, but 90% of your historical data is still on the old spec.

**Fix it:**

Ensure your big fact tables (anything over ~1 GB) are partitioned by:
- `day(event_timestamp)` — the standard for SaaS event tables.
- Plus `tenant_id` if you have multiple tenants and per-tenant queries are common.

Make sure your WHERE clauses use the partition columns with simple TIMESTAMP or DATE literals:

```sql
-- GOOD — guaranteed to prune
WHERE event_date >= TIMESTAMP '2026-05-01 00:00:00'
  AND event_date < TIMESTAMP '2026-06-01 00:00:00'

-- RISKY — may not prune depending on Trino version
WHERE DATE(event_timestamp) >= DATE '2026-05-01'
```

**Cost impact:** 50–200x reduction in data scanned per query. If this is the issue, you can cut your load in half overnight.

---

### Trap 2: Too Many Small Files (compaction forgotten)

Streaming pipelines or frequent micro-batches write one small file per write. After a month without compaction, you have thousands of tiny files. Trino spends 10–50 ms opening each file — even before reading any data.

**Diagnose it:**

```sql
-- Check file count and size per partition
SELECT
  partition,
  COUNT(*) AS file_count,
  ROUND(AVG(file_size_in_bytes / 1024 / 1024), 1) AS avg_file_mb,
  ROUND(SUM(file_size_in_bytes / 1024 / 1024), 1) AS total_mb
FROM iceberg.analytics."feature_usage$files"
GROUP BY partition
ORDER BY file_count DESC
LIMIT 20;
```

If you see partitions with hundreds or thousands of files, or average file sizes under 64 MB, compaction is needed.

**Fix it:**

Run nightly compaction via Spark (not Trino — Spark's `rewrite_data_files` is the right tool for this):

```sql
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.feature_usage',
  options => map(
    'target-file-size-bytes', '268435456',  -- 256 MB
    'min-input-files', '5'
  )
);
```

Schedule this as a Kubernetes CronJob at 4 AM (after your ingestion finishes).

**Cost impact:** 5–10x faster queries on tables with small-file buildup. Queries that took 2 minutes drop to 15 seconds.

---

### Trap 3: Forgotten Snapshot Expiry (storage debt)

Iceberg keeps every snapshot you've ever created, and every snapshot holds onto the data files it references. Without snapshot expiry, storage grows 20–30% per year even with flat business volume.

**Diagnose it:**

```sql
-- How many snapshots does your table have?
SELECT
  COUNT(*) AS total_snapshots,
  COUNT(*) FILTER (WHERE committed_at > CURRENT_TIMESTAMP - INTERVAL '7' DAY) AS last_7d,
  COUNT(*) FILTER (WHERE committed_at > CURRENT_TIMESTAMP - INTERVAL '30' DAY) AS last_30d
FROM iceberg.analytics."feature_usage$snapshots";
```

If you have thousands of snapshots but writes are infrequent, most of them are old and no longer needed.

**Fix it:**

Run weekly snapshot expiry via Spark:

```sql
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.feature_usage',
  older_than  => current_timestamp - interval '30' day,
  retain_last => 10
);
```

Run maintenance in this order:
1. `rewrite_data_files` (compaction) nightly.
2. `expire_snapshots` weekly.
3. `remove_orphan_files` weekly.

**Cost impact:** Stops storage from growing unbounded. On a table with 2 years of history, reclaims 30–50% of storage.

---

## Part 3: Query Frequency Matters as Much as Query Cost

A query that scans 100 GB is expensive. A query that scans 10 GB but runs 1,000 times per day is more expensive.

**Find the repeated queries:**

```sql
SELECT
  query,
  COUNT(*) AS daily_runs,
  ROUND(AVG(physical_input_bytes / 1024 / 1024 / 1024), 1) AS avg_gb,
  ROUND(COUNT(*) * AVG(physical_input_bytes / 1024 / 1024 / 1024), 1) AS total_gb_per_day
FROM system.runtime.tasks
WHERE completed_at > CURRENT_TIMESTAMP - INTERVAL '1' DAY
GROUP BY query
HAVING COUNT(*) > 10
ORDER BY total_gb_per_day DESC
LIMIT 20;
```

If a dashboard query runs every 30 seconds × 50 GB = 2.8 TB per day, the fix is:

1. **Cache the result in your application** (Redis, Memcached) for 60–300 seconds instead of querying live every 30 seconds.
2. **Pre-aggregate into a rollup table** that refreshes every 5 minutes instead of live.

A nightly dbt model that pre-computes "daily signups by plan" turns a 30-second fact-table scan into a 100-row lookup. One query per night instead of 2,880 queries per day — a 2,880x load reduction.

---

## Quick Audit Checklist

Use this to scan your stack right now:

- [ ] **All fact tables over 1 GB are partitioned by `day(event_date)` and/or `tenant_id`** (check via `SHOW CREATE TABLE`).
- [ ] **WHERE clauses on those tables use raw TIMESTAMP/DATE literals on partition columns** (check your BI tool filters and scheduled reports).
- [ ] **Nightly `rewrite_data_files` compaction is running** (check k8s CronJob logs; verify file counts dropped).
- [ ] **Weekly `expire_snapshots` is running** (check that old snapshots are being deleted).
- [ ] **Query history is being captured** (query `system.runtime.tasks` regularly).

If any of these are unchecked, that's where your excess cost is hiding.

---

## Summary: Where to Start

1. **This week:** Query `system.runtime.tasks` to identify your top 10 most expensive queries. Run `EXPLAIN` on each one.
2. **Next week:** Fix partition pruning on the top 3 queries. Verify they have partition columns in the WHERE clause.
3. **By next month:** Ensure compaction and snapshot expiry are scheduled. Check file counts in your big tables.
4. **Beyond:** Build rollup tables for your most-repeated queries. Implement query caching at the application layer.

If these are the issues, you're not looking at a Trino or Iceberg problem — you're looking at **operational debt** that's been accumulating for six months. Each fix above is straightforward and most pay back in days or weeks.
