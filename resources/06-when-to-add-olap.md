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

## STOP — for tables under 10M rows still taking >10 seconds, this is almost always a tuning problem, not an OLAP problem

> **Read this before you go anywhere near the proxy test.** If your slow Postgres query is hitting a table with fewer than 10M rows and it still takes more than 10 seconds, **the overwhelming probability is that the query, the indexes, or the Postgres configuration is wrong — not that you need a columnar OLAP engine.** Columnar OLAP is designed for the 100M-row–and-up regime; throwing it at a 5M-row tuning problem masks the root cause and saddles you with a second system that you now have to operate. **Exhaust the tuning checklist below FIRST.** Only if every item has been tried and the dashboard is still slow should you advance to the proxy test in Step 1A.
>
> The pattern this guards against: an engineer sees `45s` on a 5M-row table, jumps to "we need OLAP," spends six months building a lakehouse, and discovers post-migration that the original query was missing one partial index and would have run in 200ms on Postgres. This is the #1 cause of premature-OLAP regret in SaaS teams. **Sub-10M rows + 10+ seconds = tuning problem until proven otherwise.**

### The mandatory tuning-first checklist (run all of these BEFORE the proxy test)

For any Postgres query taking >10s on a table under 10M rows, work through this list **before** assuming OLAP will help:

- **`EXPLAIN (ANALYZE, BUFFERS) <your query>;`** — this is non-negotiable. Read the output for:
  - **Seq Scan on a large table** → you are missing an index. Add it.
  - **`Buffers: shared read=N`** with N huge → cold cache; the query is I/O-bound, not CPU-bound. Often fixed by warming the cache (just running the query a second time) or raising `shared_buffers`.
  - **`Sort Method: external merge Disk: N kB`** → `work_mem` is too small for the sort; the sort spilled to disk. Raise `work_mem` (session-level: `SET work_mem = '256MB';`).
  - **`Rows Removed by Filter: N`** with N large → the index is too coarse; Postgres is fetching many rows then filtering. Add a more selective index or a partial index.
- **`work_mem` sizing.** The default 4MB is far too small for analytical sorts/hashes. For a session running a slow dashboard query, `SET work_mem = '128MB';` or `'256MB';` often turns a 45s query into a 2s query without any other change. Do NOT raise `work_mem` globally (it is per-operator, per-connection — a 256MB global setting with 200 connections is 50GB of potential RAM use); raise it in the session that runs the slow query, or per role.
- **Partial indexes on hot filter predicates.** If 99% of your dashboard queries filter to `WHERE deleted_at IS NULL AND status = 'active'`, build the index with that predicate baked in: `CREATE INDEX ON events (user_id, created_at) WHERE deleted_at IS NULL AND status = 'active';`. The index is dramatically smaller and faster; Postgres reads only the surviving rows.
- **BRIN indexes for append-only time-series tables.** A `created_at`-style timestamp column on an append-only table is a perfect BRIN target: `CREATE INDEX ON events USING BRIN (created_at);`. BRIN stores one summary entry per 8MB block — for a 5M-row table, the BRIN index is kilobytes instead of hundreds of megabytes, and `WHERE created_at >= '2025-01-01'` scans roughly the right block range. BRIN is one of the most under-used Postgres features in SaaS analytics.
- **Materialized views for repeated GROUP BY shapes.** If the dashboard runs the same `SELECT user_id, COUNT(*) ... GROUP BY user_id` every page load, pre-compute it: `CREATE MATERIALIZED VIEW mv_signups_by_user AS <query>;` and `REFRESH MATERIALIZED VIEW CONCURRENTLY mv_signups_by_user;` on a schedule (hourly is usually plenty). Dashboard queries become point-lookups against the MV instead of full re-aggregations.
- **`pg_stat_user_indexes` audit.** Run `SELECT relname, indexrelname, idx_scan FROM pg_stat_user_indexes WHERE schemaname='public' ORDER BY idx_scan;`. If your slow query's table has indexes that show `idx_scan = 0`, those indexes are unused dead weight (slow INSERTs, wasted space). More importantly, if the join column or filter column has NO index at all, that is your problem.
- **`max_parallel_workers_per_gather`.** Default is 2. Raising to 4 or 8 on a beefy replica often halves wall time for sequential-scan-heavy analytical queries. Session-level: `SET max_parallel_workers_per_gather = 4;`.

**If you have not run `EXPLAIN (ANALYZE, BUFFERS)` and worked through this list, do NOT skip ahead to the proxy test.** The proxy test only answers "would columnar help?" — it does not tell you whether tuning would have helped first. Most "we need OLAP" tickets resolve on this checklist alone.

---

## Step 1A: The OLAP proxy test — before you commit to building any pipeline

Before standing up a real ingestion pipeline, run a **proxy test**: copy a representative slice of the slow Postgres table into an OLAP engine and re-run the slow dashboard query there. If the query goes from 45s to <2s, OLAP will help. If it only goes from 45s to 20s, the problem is the query shape and OLAP won't save you — go back to Step 1 (tuning).

### Step 1A.0: Use the OLAP engine you ALREADY HAVE

> **Read this first.** If your org already runs Trino + Iceberg + MinIO + Spark (this production stack does), **do NOT install DuckDB on your laptop** for the proxy test. Use the engine you already have. Installing a new tool to evaluate whether you need an OLAP engine — when you already operate one — is wasted effort and produces results that don't generalize to your production query path.
>
> | Org already runs... | Proxy-test path | Time to "yes/no" answer |
> |---|---|---|
> | **Trino + Iceberg + MinIO (this stack)** | `CREATE TABLE iceberg.scratch.events_proxy AS SELECT * FROM postgres_catalog.public.events` then re-run the slow query against `iceberg.scratch.events_proxy` | Hours — table creation + one query |
> | Snowflake / BigQuery / Redshift | `CREATE TABLE scratch.events_proxy AS SELECT * FROM <Postgres external table or COPY from S3>` then re-run | Hours |
> | ClickHouse | `INSERT INTO scratch.events_proxy SELECT * FROM postgresql('host', 'db', 'events', 'user', 'pass')` | Hours |
> | **No OLAP engine at all** | DuckDB on a laptop or a Spark sandbox — cheapest option to prove the pattern before buying anything | Day-ish |
>
> **The fundamental point:** the proxy test answers "would columnar OLAP make this query fast?" — the answer is the same regardless of *which* OLAP engine you test in. Pick the cheapest path to running the query in a columnar engine. If you already operate Trino+Iceberg, that IS the cheapest path.
>
> **"Migration" cost on an existing stack:** if your org already has on-prem Trino + Iceberg + MinIO + Spark running, "migrating a table" is **days-to-weeks** of work — adding one Iceberg table definition, scheduling one Spark ingest job, pointing one dashboard at it. It is **NOT** months of building OLAP infrastructure from scratch. The expensive part (the cluster, the metastore, the object store, the operating practice) is already paid. Don't let "migration cost" be a strawman that keeps you on Postgres past the breaking point.

### Step 1A.1: The Trino + Iceberg proxy test (preferred — this is YOUR stack)

```sql
-- One-shot copy of the slow Postgres table into Iceberg via Trino federation.
-- Substitute your actual catalog/schema/table names.
CREATE TABLE iceberg.scratch.events_proxy
WITH (
  format = 'PARQUET',
  partitioning = ARRAY['day(created_at)']   -- match the dominant filter column
)
AS
SELECT *
FROM postgres_catalog.public.events
WHERE created_at >= DATE '2024-01-01';      -- limit to a representative slice if 5M rows is too much

-- Then re-run your slow dashboard query against the Iceberg copy:
SELECT user_id, COUNT(*) AS n
FROM iceberg.scratch.events_proxy
WHERE created_at >= DATE '2025-05-01'
GROUP BY user_id
ORDER BY n DESC
LIMIT 100;
```

If this query returns in <2s while the Postgres equivalent takes 45s, columnar OLAP is your answer — and you already have it running.

### Step 1A.2: The DuckDB proxy test (ONLY if you have no OLAP engine yet)

If your org has zero OLAP engine in production, DuckDB on a developer laptop is the cheapest possible "would OLAP help?" test. DuckDB can read Postgres directly via its `postgres_scan` extension.

```sql
-- In DuckDB (install: pip install duckdb, or download the CLI):
INSTALL postgres_scanner;
LOAD postgres_scanner;

-- Pull a sample of the slow table directly from Postgres into a Parquet file.
-- This is the CORRECT DuckDB syntax — note `COPY (...) TO ... (FORMAT PARQUET)`.
-- Do NOT use `SELECT ... INTO OUTFILE` — that is MySQL syntax and DuckDB rejects it.
COPY (
  SELECT *
  FROM postgres_scan('host=pg-replica port=5432 dbname=app user=readonly password=...',
                     'public',
                     'events')
  WHERE created_at >= DATE '2024-01-01'
) TO '/tmp/events_sample.parquet' (FORMAT PARQUET);

-- Now query the Parquet file directly — no ingest step needed:
SELECT user_id, COUNT(*) AS n
FROM '/tmp/events_sample.parquet'
WHERE created_at >= DATE '2025-05-01'
GROUP BY user_id
ORDER BY n DESC
LIMIT 100;
```

> **Run the diagnostic query TWICE and use the second-run timing.** The first run pays for cold-cache I/O (reading Parquet/Iceberg files from disk or MinIO for the first time, populating OS page cache, JIT-compiling DuckDB / warming Trino splits). The second run reflects steady-state warm-cache performance, which is what your production dashboard users actually see most of the time. Reporting only the first-run number distorts the comparison — a 5s cold run that drops to 0.3s warm is a strong "yes, OLAP helps" signal that gets hidden if you only look at run 1.

### What the proxy test does NOT do

- **It does not size your production cluster.** A 5M-row sample on a laptop won't tell you how 500M rows perform on Trino under concurrency.
- **It does not validate your partition spec.** The proxy is a "is the IDEA right?" test, not a tuning exercise.
- **It does not include join cost.** If your real dashboard joins 3 tables, copy all 3 (or at least re-run the full multi-table query against the Iceberg copies).

The proxy test answers exactly one question: **"if my data were in a columnar OLAP engine, would the slow query be fast?"** — yes or no, in a few hours of effort, with the engine you already have.

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

You already have MinIO + Iceberg + Trino + Spark. **"Migrating a table" is days-to-weeks of work on this stack — not months of building OLAP from scratch.** The cluster, metastore, object store, and operating practice are already paid for. Here is what "move a table" actually looks like, in plain English:

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
