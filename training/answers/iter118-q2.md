# Iter118 Q2 — Answer

**Question**: Our Trino queries against Iceberg have been getting progressively slower over the last month, but I'm not sure where to even start diagnosing the problem. The table hasn't changed structure. We're adding about 2 million new event rows per day across roughly 80 tenants. When I look at a slow query, how do I tell whether the problem is that I wrote bad SQL, that the data is laid out poorly on disk, that too many people are running queries at the same time, or something else entirely? Is there a debugging checklist or some way to figure out what's actually causing the slowdown?

---

# Diagnosing Trino Query Performance Regressions: A Practical Checklist

When Trino queries get progressively slower, the culprit could be bad SQL, poor data layout, too many concurrent queries, or insufficient maintenance. This guide walks you through a systematic debugging process — each check takes 1-5 minutes and often makes the later ones irrelevant.

## Step 1: Check for concurrency spikes (takes 1 minute)

Open the Trino UI at `http://trino-coordinator:8080/ui/queries` and look at the query list.

**What to look for:**
- **Queued queries** — if you see queries waiting instead of running, your workers are saturated. Users experience slowness because their query sits in a queue, not because the query itself is inefficient.
- **Long-running queries** — anything consistently over 2 minutes is a candidate for the deeper steps below.
- **Query count** — normal is 5-20 concurrent queries. If you regularly see 100+, that's your problem.

**Is this the root cause?**
In the query list, sort by start time. If many queries started within the same 60-second window, concurrency is the culprit.

**Quick fix if yes:**
- Stagger dashboard refresh times (Metabase, Superset schedule settings).
- Use Trino's resource groups (per-user queues) to cap concurrent queries per tenant and prevent one tenant's dashboards from starving another's.
- Cache hot aggregations in a pre-computed rollup table so 50 dashboards query a 10-row result instead of scanning the fact table.

If you don't find queued queries but many queries are running, move to Step 2.

## Step 2: Is it all queries or just one? (takes 1 minute)

**All queries slow simultaneously:** Usually infrastructure, not a data issue. Check Trino worker health in the UI and verify MinIO is responding normally. Skip to Step 8 (data volume growth).

**One specific query regressed:** This is the common case. Continue to Step 3.

## Step 3: Run EXPLAIN ANALYZE on the slow query (takes 2 minutes)

```sql
EXPLAIN ANALYZE
SELECT tenant_id, COUNT(*) AS events
FROM iceberg.analytics.feature_usage
WHERE event_date >= CURRENT_DATE - INTERVAL '90' DAY
GROUP BY tenant_id;
```

Copy the full EXPLAIN output. Look for three numbers:

### The Files count — this is the most important number

This tells you how many Parquet files Trino opened:

| Files count | Interpretation |
|---|---|
| ~1 per day × 90 days = 90 files | Good — partition pruning is working |
| 4,860 files for 90 days | Bad — full table scan, partition pruning is broken |
| 350 files when you expect ~70 | Small files problem — compaction fell behind |

If files are much higher than expected, the WHERE clause isn't filtering on a partition column (see Step 4).

### Wall time vs CPU time

- **Wall time ≈ CPU time:** Your query is compute-bound (filters, aggregations, joins are slow).
- **Wall time >> CPU time (5-10x difference):** You're I/O-bound. Either you're reading too many files, or you're opening too many small files adding metadata overhead.

### Input: rows and bytes

Compare the input volume to what you expect. If it jumped from 500M rows last week to 5B rows today, either:
- A filter disappeared from the query (Step 6).
- The table grew significantly (Step 8).
- Partition pruning broke (Step 4).

## Step 4: Verify partition pruning is working (takes 2 minutes)

Check the table's partition spec:

```sql
SHOW CREATE TABLE iceberg.analytics.feature_usage;
```

Look for the `partitioning` clause. You'll see something like:

```
partitioning = ARRAY['day(event_date)', 'tenant_id']
```

This means the table is physically split by day and by tenant_id. Good.

**Now check your WHERE clause against the partitioning.**

| WHERE clause | Partition pruning result |
|---|---|
| `WHERE event_date >= CURRENT_DATE - INTERVAL '90' DAY` | Prunes to 90 day-partitions |
| `WHERE tenant_id = 'acme'` (when tenant_id is a partition column) | Prunes to acme files only |
| `WHERE feature_name = 'invite'` (non-partition column) | Full table scan — you read all files |
| No WHERE clause | Full table scan |

**Common regression trigger:** A query that previously used a partition column in the filter gets refactored. Example: someone changes from `WHERE event_date = CURRENT_DATE` to `WHERE DATE(event_time) = CURRENT_DATE`. The derived expression may not prune as well as the direct column reference.

**Fix:** Ensure your WHERE clause filters on a partition column directly, not a derived expression. If you must filter on a computed column, add an additional partition-column filter to help pruning:

```sql
-- Better — helps pruning by narrowing the date range first
WHERE event_date >= CURRENT_DATE - INTERVAL '90' DAY
  AND DATE(event_time) = CURRENT_DATE
```

## Step 5: Check for partition skew (takes 2 minutes)

Partition skew means one partition has far more data than others. Even with pruning working, a single oversized partition causes one Trino worker to do 100x the work of others.

```sql
-- How many rows per partition?
SELECT
  event_date,
  tenant_id,
  COUNT(*) AS row_count
FROM iceberg.analytics.feature_usage
WHERE event_date = CURRENT_DATE - INTERVAL '1' DAY
GROUP BY event_date, tenant_id
ORDER BY row_count DESC
LIMIT 20;
```

**Red flags:**
- One tenant has 200M rows, others have 50K (4,000x skew).
- One day has 10x the rows of other days.

**Fixes for skew:**

**If one tenant is enormous:**
- Create a dedicated table for that tenant: `feature_usage_acme`.
- Or build a nightly rollup: one row per tenant/day/feature, not one row per event.

**If dates are skewed:**
- Add a sub-partition: `partitioning = ARRAY['day(event_date)', 'bucket(user_id, 100)']`.
- This splits each day's data into 100 equal buckets so parallel reads are balanced.

## Step 6: Check for small files (compaction fell behind) (takes 3 minutes)

If you're adding 2 million rows per day across 80 tenants, and compaction hasn't run, files accumulate quickly. Each Parquet file has 10-50 ms metadata overhead. 9,000 small files = 4+ minutes of file-open overhead before reading any data.

**Check if compaction is running:**

```bash
kubectl get cronjobs -n data-platform
kubectl logs -l job-name=iceberg-compaction -n data-platform --since=24h
```

Is the CronJob in the list? Are the logs showing successful runs? If the CronJob is missing or failing silently, compaction isn't happening.

**Check file counts:**

```sql
-- Show file counts in the latest snapshots
SELECT
  snapshot_id,
  committed_at,
  operation,
  summary['total-data-files'] AS total_data_files,
  summary['added-data-files'] AS added_data_files
FROM iceberg.analytics."feature_usage$snapshots"
ORDER BY committed_at DESC
LIMIT 10;
```

**Red flags:**
- `total_data_files` is in the tens of thousands for a table that's only 10 GB — you have too many small files.
- This count has been growing steadily over the past month — compaction hasn't run.

**How to fix — run compaction in Spark:**

```python
# Submit via spark-submit or in an Airflow DAG
spark.sql("""
    CALL iceberg.system.rewrite_data_files(
      table => 'analytics.feature_usage',
      options => map(
        'target-file-size-bytes', '268435456',
        'min-input-files', '5'
      )
    )
""")
```

After compaction, 9,000 files collapse to ~40-50 files (256 MB each). Query time drops from 5+ minutes to seconds.

**Important:** Compaction alone doesn't free disk space. You also need to expire old snapshots:

```python
spark.sql("""
    CALL iceberg.system.expire_snapshots(
      table => 'analytics.feature_usage',
      older_than => current_timestamp - interval '30' day,
      retain_last => 10
    )
""")
```

Without this, the old small files are still on MinIO because the old snapshots still reference them. Storage only drops visibly after both compaction AND snapshot expiry have run.

## Step 7: Check the data model (takes 5 minutes)

If partition pruning is working and files look reasonable, the slowdown is likely from query complexity.

**Did something change in the query?**

Compare your query against the version that was fast. Sometimes a `WHERE` clause gets accidentally removed, or a column gets renamed and the filter is now dead.

**Signs of data model regression:**

- The query now has 3+ table JOINs where it previously had 1-2.
- A new subquery or window function was added.
- A dimension table join was added to what used to be a simple fact table scan.

**Fixes:**
- **Denormalize:** pre-join dimension tables into a wide fact table. Queries don't join at query time.
- **Pre-aggregate:** compute the expensive aggregation nightly and store in a rollup table. The dashboard query reads 10 rows instead of 1B.
- **Simplify the join:** ensure the larger table appears first in the FROM clause; Trino's planner uses that as a hint.

## Step 8: Check data volume growth (takes 2 minutes)

Sometimes "performance regression" is just "the table grew 3x last month." This isn't a bug — it's expected growth. But the query plan needs optimization.

```sql
SELECT
  event_date,
  COUNT(*) AS daily_rows,
  SUM(COUNT(*)) OVER (ORDER BY event_date) AS cumulative_rows
FROM iceberg.analytics.feature_usage
WHERE event_date >= CURRENT_DATE - INTERVAL '90' DAY
GROUP BY event_date
ORDER BY event_date;
```

If rows per day jumped significantly (new customer, product launch), queries are doing more work correctly. The fix is optimization, not a bug hunt:
- Pre-aggregate hot paths into rollup tables.
- Narrow time ranges in dashboard queries.
- Add caching at the application layer (Redis, Memcached) for 60-300 seconds.

---

## Quick decision tree

Use this to skip to the most likely culprit:

| Symptom | First check | Likely fix |
|---|---|---|
| All queries slow at the same time | Trino UI concurrent query count | Stagger refreshes, resource groups |
| One query slow, others fine | EXPLAIN ANALYZE Files count | Add partition filter, run compaction |
| Slow consistently, no obvious time pattern | File count in `$snapshots` | Run compaction nightly via CronJob |
| Slow after a query code change | EXPLAIN ANALYZE Input rows vs baseline | Restore filter, simplify JOIN |
| Slow for one tenant only | Rows by tenant partition | Dedicated table or nightly rollup for big tenant |
| OOM errors on Trino workers | EXPLAIN ANALYZE memory estimate | Pre-aggregate, lower cardinality GROUP BY |

---

## Key takeaway

The three most common causes of progressive slowdown in this setup are:

1. **Small files accumulating** — compaction jobs didn't run or are failing silently (90% of cases).
2. **Partition pruning broken** — a query filter changed to use a non-partition column or a derived expression.
3. **Concurrency spike** — more dashboards, more batch jobs, more users hitting queries simultaneously.

Run the checks in order; the first few take minutes and often pinpoint the issue without needing to dig deeper.
