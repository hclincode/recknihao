# Answer to Q1: When to Move from Postgres to a Separate Analytics System

## The Core Principle

Your team member who said "Postgres will always struggle with aggregations across many customers" is technically correct, but incomplete. Your other team member who said "try optimization first" is also right. The question is: **which optimization hits the wall first?**

Postgres optimization (read replicas, indexes, partitioning) can take you very far, especially for 5–10 million rows per customer. But there are structural limits you'll eventually hit that no amount of tuning fixes. The trick is distinguishing between "we haven't tuned this yet" and "we've hit the wall."

## Step 1: You Must Exhaust Postgres Optimization First

Don't move until you've tried this checklist. Most SaaS teams skip this and move too early, then operate two systems forever:

1. **Read replica** — Point all analytics traffic at a read replica, not the primary. This alone solves ~60% of "analytics is breaking the app" problems. Zero risk. Do this immediately if you haven't.

2. **Materialized views** — Pre-compute your dashboard's GROUP BY result on a schedule. `REFRESH MATERIALIZED VIEW signups_by_plan_daily;` once an hour. Dashboards now do a point-lookup instead of scanning millions of rows.

3. **Partial indexes** — `CREATE INDEX ON events(user_id) WHERE deleted_at IS NULL`. Much smaller than indexing the whole table, much faster for soft-deleted SaaS data.

4. **`pg_partman` table partitioning** — Split a growing events table into monthly partitions. Queries with `WHERE created_at >= '...'` only scan the partitions they need, not the whole table.

5. **Connection pooling** — If analytics tools are opening 200 connections, you don't need OLAP; you need PgBouncer. Analytics threads should have a limited pool.

6. **`EXPLAIN ANALYZE` every slow query** — Often a dashboard query is slow because of one missing index or an unnecessary sort, not because of data volume.

If after all this your dashboards are still slow, keep reading. If not, **stay on Postgres** — you're not ready to move.

## Step 2: The Concrete Thresholds

Don't decide based on gut feel. Use these numbers:

| Signal | Threshold | What it means |
|---|---|---|
| **Largest analytical table** | >50M rows *and* growing >10%/month | Growth is outpacing your optimization's ability to keep up |
| **Dashboard query latency** | >2 seconds (p95) *after* tuning | Scanning and aggregating is genuinely slow, not just unoptimized |
| **Number of ad-hoc queryers** | >3 people running queries regularly | Analytics is becoming a real workload, not one person's occasional report |
| **Source systems to join** | >1 (Postgres + Stripe + product analytics) | You need data from multiple places; Postgres can't be the only source |
| **Daily analytics CPU on Postgres** | >20% of primary capacity | Analytics is competing noticeably with your application |

**Rule:** If **two or more** of these thresholds are true, move to OLAP. If only one, optimize Postgres harder.

For your situation right now (15,000 customers, 5–10M rows per customer, mostly 90-day queries), you almost certainly haven't hit the 50M row threshold on your main analytical tables. And if you have, the question becomes: did you try materialized views and partitioning first?

## Step 3: The Honest Assessment of Postgres Limits

Your team member is right that aggregations across *all* customers will struggle eventually. Here's why:

Postgres is **row-oriented**. When you ask `COUNT(*) FROM events WHERE created_at >= '2024-01-01' GROUP BY account_id`, Postgres must:
- Scan every row that matches the date
- Read all columns of each row from disk
- Extract just two columns (created_at, account_id)
- Throw away the rest

If your events table is 100M rows with 30 columns, Postgres reads 100M full rows off disk even though it only *needs* two columns. A columnar system (like Trino over Iceberg) reads only those two columns from object storage — often a 10–50x reduction in I/O.

Additionally, a long analytical scan on a read replica can cause replication lag. While your aggregation runs for 3 minutes, the replica can't apply newer writes that would conflict with your query. During peak hours, you may see stale data in your application.

**But here's the catch:** these problems only *matter* if you're actually hitting them. A 10M row table with partitioning and materialized views will stay fast for years.

## Step 4: Decision Tree

```
Is your largest analytical table > 50M rows?
├── No  → Execute the Postgres tuning checklist. STOP here.
│         You are not ready to move. Revisit in 6 months.
│
└── Yes → Are dashboards still > 2 seconds after tuning?
         ├── No  → Stay on Postgres + materialized views. STOP.
         │         You've solved it without complexity.
         │
         └── Yes → Do you need to join > 1 source system?
                  ├── No  → Move that one table to Iceberg.
                  │         Keep everything else on Postgres.
                  │
                  └── Yes → Move the entire analytical workload to the lakehouse.
                            Postgres handles the application only.
```

## Step 5: What Moving Actually Looks Like (Your Stack)

You already have MinIO, Spark, Iceberg, and Trino on-prem. Here's the pattern:

1. **Spark job reads Postgres** via JDBC. Nightly, do a full snapshot: `SELECT * FROM events WHERE created_at >= ...`
2. **Spark writes Parquet to MinIO** — partitioned by date and tenant.
3. **Iceberg registers the table** in Hive Metastore.
4. **Trino queries it** — your BI tool points to `SELECT ... FROM iceberg.analytics.events` instead.
5. **Cron or Airflow runs the Spark job** nightly (or hourly, depending on freshness needs).

**Start with one table.** Usually `events` or `feature_usage`. Prove the pattern on a single dashboard, then expand.

## The Cost of Moving Too Early vs Too Late

**Moving too early (when 5–10M rows, untuned Postgres):**
- You're now running two systems
- Two schemas to keep in sync
- Queries scattered between Postgres and Trino
- Data team debugging "where is the truth" questions
- Six months later: "We never use the lakehouse"

**Moving too late (when 200M rows, Postgres buckling):**
- Dashboards timeout and users stop running reports
- App performance tanks because analytics starves Postgres
- Data team builds shadow scripts and hidden warehouses
- Migration becomes urgent and messy

## What to Do Next

1. **Run `EXPLAIN ANALYZE`** on your three slowest dashboard queries. If the problem is a missing index, you have work to do.

2. **Deploy a read replica** if you don't have one. Measure analytics CPU on the primary before and after.

3. **Set up 2–3 materialized views** for your most-queried reports. Refresh them hourly. Measure query latency.

4. **Check your table sizes:**
   ```sql
   SELECT schemaname, tablename,
          pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename))
   FROM pg_tables
   WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
   ORDER BY pg_total_relation_size DESC
   LIMIT 10;
   ```

5. **Measure** dashboard latency and analytics CPU after tuning. If you're still above the thresholds (>2s, >20% CPU), and you've truly exhausted Postgres, *then* plan the Iceberg migration.

The biggest mistake teams make is skipping steps 1–3 and learning Spark because a blog post made it sound important. Don't be that team. Tune Postgres first. You'll feel much better about moving when you've proven you actually need to.
