# When to Add an OLAP Layer vs Staying on Postgres

> **Production note:** Your stack already has the OLAP layer available (MinIO + Iceberg + Trino, on-prem k8s, with Spark for ingestion). So "adding OLAP" here means *starting to use the lakehouse you already have* — not buying a new product. The decision is whether a given workload should live on Postgres or move to Iceberg.

---

## Quick answer

1. **Exhaust Postgres tuning first** — most SaaS teams jump too early and end up running two systems forever.
2. **Move to OLAP when at least two of these hit:** >50M rows in the analytical table, dashboard queries >2s after tuning, >3 people running ad-hoc queries, or you need to join data from >1 source system.
3. **Migration path on this stack:** Spark snapshot job reads Postgres → writes Parquet → registers as Iceberg table → Trino queries it. Start with one table.
4. **The cost of moving too early:** two systems to operate, two schemas to keep in sync, two query languages in your codebase, double the on-call surface.
5. **The cost of moving too late:** dashboards time out, app users get slow pages because analytics queries are starving Postgres, and the data team builds shadow scripts.

---

## Step 1: The Postgres tuning checklist (try these FIRST)

Before standing up any pipeline, work through this list. Most "we need a warehouse" problems are actually "we never tuned Postgres."

- **Read replica.** Point all analytics traffic at a streaming replica. Zero risk to the primary. Solves 60% of "analytics is slowing down the app" problems by itself.
- **Partial indexes.** `CREATE INDEX ON events(user_id) WHERE deleted_at IS NULL` — much smaller and faster than indexing the whole table. Perfect for soft-deleted SaaS data.
- **Materialized views.** Pre-compute the dashboard's GROUP BY result on a schedule. `REFRESH MATERIALIZED VIEW signups_by_plan_daily;` once an hour. Dashboards now do a point-lookup instead of a scan.
- **`pg_partman` for table partitioning.** Split a 200M-row `events` table into one partition per month. Queries with `WHERE created_at >= '...'` only scan the partitions they need.
- **Connection pooling (PgBouncer).** If your analytics tool opens 200 connections and the app dies, you don't need OLAP — you need a pooler.
- **`EXPLAIN ANALYZE` every slow query.** Half the time the slow query is missing one index or doing an unnecessary sort.

If after all of this your dashboards are still slow, *then* keep reading.

---

## Step 2: Concrete thresholds for moving to OLAP

Don't move based on a feeling. Use numbers:

| Signal | Threshold |
|---|---|
| Largest analytical table | >50M rows and growing >10%/month |
| Dashboard query latency after tuning | >2s p95 |
| Number of ad-hoc queryers | >3 people |
| Source systems to join | >1 (Postgres + Stripe + product analytics) |
| Daily analytics CPU on Postgres | >20% of primary capacity |

If two or more of these are true, the lakehouse pays for itself.

---

## Step 3: Decision tree (text form)

```
Is your largest analytical table > 50M rows?
├── No  → Try Postgres tuning checklist. STOP here.
└── Yes → Are dashboards still > 2s after tuning?
         ├── No  → Stay on Postgres + materialized views. STOP.
         └── Yes → Do you need to join > 1 source system?
                  ├── No  → Move that one table to Iceberg. Keep Postgres for everything else.
                  └── Yes → Move the analytical workload to the lakehouse. Postgres stays for the app only.
```

---

## Step 4: The migration path on YOUR stack

You already have MinIO + Iceberg + Trino + Spark. Here is what "move a table" actually looks like, in plain English:

1. **Spark job reads Postgres.** Use Spark's JDBC source to `SELECT * FROM events WHERE created_at >= ...`. For a first cut, do a nightly full snapshot. CDC (change data capture) comes later.
2. **Spark writes Parquet to MinIO.** Spark partitions the output by date and writes Parquet files into an S3-compatible bucket on MinIO.
3. **Register the table in Iceberg via Hive Metastore.** Spark creates the Iceberg table definition; the Metastore now knows the table exists.
4. **Trino queries it.** Point your BI tool or notebook at Trino with the Iceberg catalog. Your dashboard query is now a `SELECT ... FROM iceberg.analytics.events` instead of hitting Postgres.
5. **Schedule the Spark job.** Cron or Airflow, once an hour or once a day depending on freshness needs.

Start with **one table** (usually `events` or `feature_usage`) and one dashboard. Prove the pattern, then expand.

---

## The #1 mistake: adding OLAP too early

A team with 8M rows in Postgres reads a Snowflake blog post, spins up a lakehouse, then spends six months running both. Their dashboards aren't any faster (8M rows wasn't the bottleneck — a missing index was), they now have two schemas drifting apart, and engineers debate which system has "the truth."

**Rule:** if you can't articulate which Postgres tuning step failed, you're not ready to move.

---

## Key terms

| Term | Meaning |
|---|---|
| **Read replica** | A streaming copy of Postgres you can query without touching the primary |
| **Materialized view** | A query whose result is stored as a table and refreshed on a schedule |
| **`pg_partman`** | A Postgres extension that automates time-based table partitioning |
| **Snapshot ingestion** | A full copy of a source table written to the lakehouse on a schedule |
| **CDC (Change Data Capture)** | Streaming only the changed rows from Postgres into the lakehouse |
| **Hive Metastore** | The catalog service Trino and Spark both use to know which Iceberg tables exist |
