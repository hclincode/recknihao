# Iter137 Q2 — Answer

**Question**: "We already have Trino and Iceberg set up on-prem as part of our stack — it's there, it's running, we're ingesting some data into it. But our analytics dashboards are still hitting Postgres directly because my team is nervous about the operational cost of fully committing: someone has to maintain compaction jobs, monitor query failures, keep Hive Metastore healthy, and so on. The argument for staying on Postgres is 'it's already working, we understand it, and we've already added indexes and a read replica.' How do I actually figure out whether flipping the dashboards to Trino/Iceberg is worth that ongoing maintenance burden — is there a practical way to test it without a full migration, and what are the real operational costs people underestimate when they go all-in on a setup like this?"

---

## The Practical Test: A/B Query Execution Without a Full Migration

Don't guess — measure. The cleanest approach is **parallel dual-query execution**: run each dashboard query against both Postgres and Trino/Iceberg simultaneously, log the latencies, and collect data over 2–4 weeks before deciding.

**Implementation:**

```python
import time
import hashlib
import psycopg2
import trino

def run_dual_query(postgres_conn, trino_conn, pg_sql, trino_sql, query_name):
    results = {}

    # Run Postgres
    t0 = time.monotonic()
    with postgres_conn.cursor() as cur:
        cur.execute(pg_sql)
        pg_rows = cur.fetchall()
    results['postgres_ms'] = int((time.monotonic() - t0) * 1000)
    results['postgres_checksum'] = hashlib.md5(str(sorted(pg_rows)).encode()).hexdigest()

    # Run Trino
    t0 = time.monotonic()
    with trino_conn.cursor() as cur:
        cur.execute(trino_sql)
        trino_rows = cur.fetchall()
    results['trino_ms'] = int((time.monotonic() - t0) * 1000)
    results['trino_checksum'] = hashlib.md5(str(sorted(trino_rows)).encode()).hexdigest()

    results['query_name'] = query_name
    results['match'] = results['postgres_checksum'] == results['trino_checksum']
    return results
```

Log all results to a simple table or file. After 2 weeks, analyze:
- P50, P95, P99 latency for each engine per query.
- Checksum match rate (results must be identical — divergence means stale data or a modeling error).
- EXPLAIN output from both to understand why latencies differ.

**Why 2 weeks minimum:** Iceberg's Parquet metadata is cached by Trino's coordinator. MinIO's object cache warms over time. Postgres page cache works differently. One day of data reflects cold-start behavior, not steady state.

---

## Real Operational Costs: What People Underestimate

Your team is right to be cautious. The engineering cost of running Iceberg is real. Here is a breakdown by category with honest estimates.

### 1. Compaction Jobs — 0.1–0.2 FTE/year

Iceberg never modifies files in place. Every write creates new small files. Without compaction, a single day's partition can accumulate thousands of files under 10 MB each, and query times degrade week over week.

**What compaction requires:**
- A nightly Kubernetes CronJob or Airflow task running `CALL iceberg.system.rewrite_data_files(...)` during low-traffic hours.
- Compute: 2–8 vCPU-hours per nightly run depending on table size. Usually cheap on a cluster with slack capacity overnight.
- **Setup cost (one time):** 30–40 hours to write the job, handle failure modes (OOM, network partition, Metastore timeout), and build alerting for silent failures.
- **Ongoing cost:** 2–4 hours/month troubleshooting failed runs, tuning `target-file-size-bytes` as data volume grows.

**What breaks if you skip it:** Small-file accumulation. A table with 500,000 files causes manifest reads alone to take 30+ seconds. Dashboards slow to a crawl, silently, over 2–3 months.

### 2. Snapshot Expiry and Orphan Cleanup — 0.05 FTE/year

Iceberg keeps every snapshot indefinitely by default. Unreferenced data files stay in MinIO forever unless you explicitly expire snapshots.

**What snapshot expiry requires:**
- Weekly or daily scheduled run: `ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '30d')`.
- Orphan file cleanup: `ALTER TABLE iceberg.analytics.events EXECUTE remove_orphan_files(retention_threshold => '7d')` — the 7-day window protects in-flight writes from being deleted.
- Setup: 4–8 hours to build and test; ongoing: minimal (mostly automated).

**What breaks if you skip it:** MinIO capacity grows 20–30% per year from unreferenced files even if business volume is flat. After 18 months, you're paying for 2.5× as much storage as you actually need. Recovery from years of accumulation is a one-time Spark job that burns CPU and blocks other work.

### 3. Hive Metastore Health — 0.1 FTE/year

The Hive Metastore is the single point of failure for your entire stack. If it's down, Trino can't plan queries, Spark can't write, dbt can't run.

**What Metastore maintenance requires:**
- **Uptime monitoring:** JVM heap pressure, connection pool exhaustion, slow query detection. If the Metastore DB (typically Postgres or MySQL) is under pressure, all operations queue up.
- **Backups:** Daily automated snapshots of the Metastore database. If the Metastore DB corrupts, table pointers are gone — you cannot recreate the mapping between Iceberg metadata and MinIO paths without backups.
- **Tuning:** As the number of tables and partitions grows, Metastore queries slow down. `SHOW PARTITIONS iceberg.analytics.huge_table` can take 30+ seconds against 50,000 partition entries without connection pool and JVM tuning.
- **High availability:** A single Metastore instance is a hard single point of failure. On-prem deployments typically run two Metastore instances behind a load balancer. Setting this up takes 20–30 hours initially.

**Rough ongoing cost:** 1 engineer-day per month for monitoring, incident response, and tuning = 12 days/year.

### 4. Query Debugging and Schema Drift — 0.2–0.3 FTE/year

When a dashboard query suddenly returns 0 rows or takes 10× longer, diagnosing the cause is genuinely hard.

**Common failure modes:**
- **Partition pruning regression:** A new filter on a non-partition column causes a full table scan. EXPLAIN shows "847 files" where it used to show "12 files." You debug with EXPLAIN ANALYZE, find the missing partition predicate, push a dashboard fix.
- **Schema evolution surprises:** `ALTER TABLE ... ADD COLUMN` is metadata-only in Iceberg — safe for the table. But BI tools and dbt models sometimes cache old schemas. Old dashboards miss new columns; new dashboards show NULL for historical rows where the column didn't exist yet.
- **Ingestion silence:** Spark job writes to Iceberg for 3 hours, then OOMs mid-batch. Dashboards serve stale data. No one knows until a customer reports a discrepancy. You need a freshness check: compare Iceberg row count to source, page if they diverge > 0.1%.

**Rough cost:** 15 minutes per day across the data team for reactive debugging. That's ~90 hours/year, though it's diffuse (many engineers, small amounts each).

### 5. On-Call Incident Response — 0.1–0.2 FTE/year

The incidents that actually page someone at 2 AM:

- **Ingestion job hanging mid-commit:** Spark hangs while writing to Iceberg (Metastore timeout, MinIO network partition). The table is in an inconsistent state. Recovery: `CALL iceberg.system.rollback_to_snapshot(...)`, then restart ingestion from the last checkpoint. Needs the on-call engineer to know the runbook.
- **OOM from an analyst query:** Someone runs `SELECT DISTINCT user_id FROM events` on 500M rows. The Trino worker OOMs and the cluster becomes slow. Kill the query: `CALL system.runtime.kill_query(query_id => '...')`. Implement query memory limits and resource groups to prevent recurrence.
- **Compaction job failure:** Nightly compaction crashed (disk full, pod evicted). Requires manual re-run, coordination with the team on timing.

**Rough cost:** 1–2 incidents per month × 45 minutes each = 18–36 hours/year plus on-call scheduling overhead.

### Total FTE Estimate

| Category | Annual cost |
|---|---|
| Compaction jobs | 0.06–0.1 FTE |
| Snapshot expiry/cleanup | 0.02–0.05 FTE |
| Metastore health | 0.06–0.1 FTE |
| Query debugging / schema drift | 0.1–0.15 FTE |
| On-call incidents | 0.05–0.1 FTE |
| **Total** | **0.3–0.5 FTE/year** (steady state, after initial setup) |

**Initial setup (one-time):** 4–8 weeks of one engineer's time to build all monitoring, alerting, compaction pipelines, and runbooks. This is not included in the steady-state numbers above.

---

## When Postgres Wins vs When Trino/Iceberg Wins

### Postgres wins when:

| Condition | Why Postgres is fine |
|---|---|
| Analytical table < 50M rows | Indexes cover common patterns; sequential scans are fast on small data |
| Dashboard P95 latency < 2s after tuning | No user pain; Iceberg overhead not justified |
| Single source system | No cross-system joins needed; Postgres can do everything |
| < 3 concurrent analytical queryers | Postgres read replica handles the load; no contention |
| Data team is tiny (1–2 people) | 0.3–0.5 FTE Iceberg overhead is proportionally large |

**Example:** 40M events, P95 dashboard latency 1.8s on a read replica, 2 people running ad-hoc queries. Postgres wins. Invest in a materialized view or two, not a lakehouse.

### Trino/Iceberg wins when:

| Condition | Why the switch pays off |
|---|---|
| Table > 100M rows AND growing > 10%/month | Postgres index maintenance slows; file-level pruning in Iceberg scales linearly |
| Dashboard P95 > 3s after thorough Postgres tuning | You've built indexes, read replicas, materialized views — still slow |
| > 5 concurrent analytical queryers regularly | Postgres read replica CPU-bound; Iceberg distributes scans across workers |
| Multi-source analytics needed | Joining Postgres + Stripe + Mixpanel requires a lakehouse or ETL; Iceberg centralizes |
| Tenant isolation or column-level access control | OPA + Trino is cleaner than Postgres row security at 80-tenant scale |

**Example:** 250M events, growing 15M/month, P95 dashboard latency 4s on a tuned read replica, 5 teams running ad-hoc queries simultaneously. Trino/Iceberg is justified. The ~0.4 FTE ongoing cost is offset by avoiding Postgres read-replica scaling ($20k+/year in infra) and eliminating app DB read contention.

---

## Query Patterns That Expose the Postgres Performance Cliff

These patterns start hurting at 50M–100M rows on Postgres and become table stakes for Trino/Iceberg.

### Pattern 1: High-Cardinality GROUP BY Over Time Ranges

```sql
-- Shows revenue per tenant for the last 90 days
SELECT tenant_id, SUM(amount) AS revenue
FROM events
WHERE created_at >= CURRENT_DATE - INTERVAL '90 days'
GROUP BY tenant_id
ORDER BY revenue DESC;
```

**On Postgres (100M rows):** Sequential scan of 25M rows in range, hash aggregate with 80K distinct tenant_ids. 20–40 seconds. Ties up the replica.

**On Trino/Iceberg:** Partition pruning on `day(created_at)` skips 75% of files. Columnar scan reads only `tenant_id` and `amount` (2 columns). Distributed hash aggregate. 2–4 seconds.

**Speedup: 5–15×.**

### Pattern 2: Multi-Table Join at Scale

```sql
-- Revenue by plan tier: joins events, users, subscriptions
SELECT u.plan_type, COUNT(e.event_id) AS events, AVG(s.monthly_value) AS avg_mrr
FROM events e
JOIN users u ON e.user_id = u.id
JOIN subscriptions s ON u.id = s.user_id
WHERE e.created_at >= CURRENT_DATE - INTERVAL '90 days'
GROUP BY u.plan_type;
```

**On Postgres (100M events, 500K users):** Hash join between 25M events and 500K users produces a large intermediate. Three-way join with subscriptions materializes another intermediate. Postgres handles this on a single node. 30–60 seconds.

**On Trino/Iceberg:** Partition pruning eliminates 75% of event files. `users` table is broadcast-replicated to all workers. Distributed hash join processes different ranges in parallel. 3–8 seconds.

**Speedup: 5–10×.**

### Pattern 3: Wide Scan With Non-Indexed Filter

```sql
-- Feature adoption analysis: filter on feature_name (not indexed)
SELECT user_id, COUNT(*) AS uses
FROM events
WHERE created_at >= CURRENT_DATE - INTERVAL '30 days'
  AND feature_name = 'video_upload'
  AND is_error = false
GROUP BY user_id;
```

**On Postgres:** Even with an index on `(created_at, feature_name)`, the `is_error = false` filter is applied post-scan. Reads 5M rows, discards 4.5M. 5–15 seconds.

**On Trino/Iceberg:** Columnar projection reads only `created_at`, `feature_name`, `is_error`, `user_id` (4 of 30 columns). All three filters are pushed down into the Parquet reader. 1–2 seconds.

**Speedup: 5–10×.**

### Pattern 4: Time-Series With Zero-Fill

```sql
-- Signups per day for 90 days, including days with zero signups
WITH all_dates AS (
  SELECT CAST(CURRENT_DATE - n AS DATE) AS day
  FROM UNNEST(SEQUENCE(0, 89)) AS t(n)
),
daily AS (
  SELECT DATE(created_at) AS day, COUNT(*) AS signups
  FROM events
  WHERE event_name = 'signup'
    AND created_at >= CURRENT_DATE - INTERVAL '90 days'
  GROUP BY DATE(created_at)
)
SELECT a.day, COALESCE(d.signups, 0) AS signups
FROM all_dates a
LEFT JOIN daily d ON a.day = d.day
ORDER BY a.day;
```

**On Postgres:** `DATE(created_at)` breaks index usage. Sequential scan of 90-day range. 10–20 seconds at 100M+ rows.

**On Trino/Iceberg:** Partition pruning on `day(created_at)` skips files outside the range. Columnar scan on `created_at` and `event_name` only. 1–3 seconds.

**Speedup: 5–10×.**

---

## What to Monitor After Migration

Once dashboards are on Trino, watch these signals to know if things are working.

### Query Latency Trends

```sql
-- In Trino: recent dashboard query performance
SELECT
  query,
  COUNT(*) AS runs,
  APPROX_PERCENTILE(end - created, 0.5) AS p50_ms,
  APPROX_PERCENTILE(end - created, 0.95) AS p95_ms
FROM system.runtime.queries
WHERE state = 'FINISHED'
  AND created >= NOW() - INTERVAL '1' DAY
GROUP BY query
ORDER BY p95_ms DESC
LIMIT 20;
```

Alert if any dashboard query's P95 jumps > 50% from the A/B test baseline.

### Correctness Check (Freshness + Row Count)

```sql
-- Nightly: compare Iceberg and Postgres row counts for recent data
-- (Run in a Spark or Airflow job that can access both)
SELECT
  'postgres' AS source,
  DATE(created_at) AS day,
  COUNT(*) AS rows
FROM postgres.public.events
WHERE created_at >= CURRENT_DATE - 1
GROUP BY DATE(created_at)

UNION ALL

SELECT
  'iceberg' AS source,
  DATE(event_ts) AS day,
  COUNT(*) AS rows
FROM iceberg.analytics.events
WHERE event_ts >= CURRENT_DATE - 1
GROUP BY DATE(event_ts);
```

Alert on any day where the counts diverge > 0.1% — it signals ingestion lag or a silent pipeline failure.

### File Count Health (Compaction Effectiveness)

```sql
SELECT
  COUNT(*) AS total_files,
  AVG(file_size_in_bytes) / 1048576.0 AS avg_file_mb,
  MIN(file_size_in_bytes) / 1048576.0 AS min_file_mb
FROM iceberg.analytics."events$files";
```

Alert threshold: `avg_file_mb < 10` or `total_files > 50000` for a 100M-row table means compaction is behind.

### Partition Pruning Health

Run EXPLAIN on your most critical dashboard query daily and extract the file count:

```sql
EXPLAIN
SELECT tenant_id, SUM(amount)
FROM iceberg.analytics.events
WHERE event_ts >= CURRENT_DATE - INTERVAL '90' DAY
GROUP BY tenant_id;
```

Expected: "files: ~90" (one per day of history). If you see "files: 4000+" (full table scan), pruning broke — investigate the partition spec or whether the filter was accidentally removed from the dashboard query.

---

## The Honest Decision Framework

**Do the migration if:**
1. Your dashboard P95 latency is > 3s after thorough Postgres tuning (indexes, read replica, materialized views).
2. Your analytical table has > 100M rows and is growing > 10%/month.
3. You have > 5 concurrent analytical queryers regularly starving the app DB.
4. You can commit 0.3–0.5 FTE of ongoing engineering bandwidth to operations.

**Stay on Postgres if:**
1. Dashboard latency is acceptable (< 2s P95) after tuning — don't fix what isn't broken.
2. Your table is < 50M rows — Postgres is genuinely fast at that scale.
3. You don't have the engineering bandwidth for Iceberg operations — an undermaintained Iceberg stack degrades faster than an undermaintained Postgres.

**The A/B test tells you which case you're actually in.** Run it for 2–4 weeks before deciding. If Trino is only 1.5× faster than tuned Postgres on your specific queries, the operational overhead is not worth it. If Trino is 5–10× faster, the math changes significantly.

**Stagger the cutover:** Don't flip all dashboards at once. Start with the lowest-risk, least-critical dashboard. Run both in parallel for one week. Verify correctness. Then flip the next. This way you revert quickly if something breaks rather than emergency-rolling-back a fleet of dashboards.
