# Answer to Q2: Cost Model for Analytical Workloads at SaaS Scale (Iter 313)

You're right to be concerned about billing surprises — they're very real. The good news is that your situation (80 customers, 500M rows, sustained query load) is exactly where self-hosted Iceberg+Trino wins on cost. The honest answer is that the win is mostly in engineering discipline, not in some magic "cheap per-query" number.

## What You Pay For

**On managed cloud (BigQuery, Snowflake), you pay per TB scanned.** With 500M rows, a typical dashboard query might scan 10–30 GB per run. If customers hit dashboards constantly throughout the day, you could easily scan 250–500 TB per month. At BigQuery's ~$2.50/TB (after cache hits), that's $625–$1,250/month just in query costs. Snowflake's compute credits are different (pay for running warehouse, not bytes scanned), but a medium warehouse at moderate load runs $300–$600/month.

**On your on-prem stack (Trino + Iceberg + MinIO on Kubernetes), the per-query marginal cost is effectively zero.** Your cluster is fixed nodes running 24/7. Adding one more query doesn't trigger a bill. But this hides costs elsewhere.

## Cost Layer #1: Storage (usually small after compression)

500M rows is not a lot of data. Parquet with Zstd compression (Iceberg's default) typically compresses SaaS event data 5–10x. If your event rows average ~200 bytes each, that's 100 GB raw → **10–20 GB compressed for year 1**.

On bare-metal MinIO that's already provisioned, storage is essentially free. If you needed to add disks, amortize over 3–5 years — probably $100–200/year.

**One trap to avoid:** if you don't run weekly `expire_snapshots` (the Iceberg maintenance call that deletes old table snapshots and reclaims orphaned files), storage creeps 20–30% per year even if your raw data is flat. Schedule it weekly — it costs nothing but a cron entry.

## Cost Layer #2: Compute (fixed cluster running 24/7)

A Trino cluster sized for your 80 customers — roughly 4 workers × 16 vCPU / 64 GB RAM — reserves 64 vCPU and 256 GB RAM constantly, whether anyone is querying or not. If your org charges back at even $0.03/vCPU-hour internally, that's ~$1,400/month just to keep Trino warm.

Add Spark ingestion jobs: those burn CPU during nightly compaction and batch ingestion runs. Budget 10–20 extra executor pods at peak ingestion.

**The honest comparison:** a Snowflake medium warehouse at $300–600/month is comparable in cost to the compute reservation for your on-prem Trino cluster. The difference is visibility — cloud costs are on an invoice; on-prem costs are in headcount and capacity planning.

## Cost Layer #3: Engineering Time (the biggest line item)

This is where 80% of teams get blindsided. Running a lakehouse requires:

- **Ingestion job maintenance** — Spark pipelines need monitoring, error handling, and fixes when Postgres schemas change
- **Nightly compaction** — `rewrite_data_files` to merge tiny Parquet files into ~256 MB chunks; automates via cron but needs monitoring
- **Snapshot expiry** — weekly cleanup so MinIO storage doesn't balloon
- **On-call when things break** — a crashed ingestion job means stale dashboards; without alerting, analysts Slack you asking "why is data frozen?"
- **Hive Metastore care** — single point of failure for Spark, Trino, and dbt; needs backups, monitoring, and HA

Realistic full-year estimate: **0.5–1.0 FTE** for baseline maintenance at your scale. At $200k fully-loaded salary, that's **$100k–$200k/year** — easily 10–50x larger than your compute bill.

Comparison: on managed cloud (Snowflake/BigQuery), you drop to 0.1–0.2 FTE because the provider handles cluster management, compaction, and storage. If you can actually move that FTE to a higher-value project, cloud is $60k–$100k/year cheaper despite the higher compute bill.

## Three Architectural Decisions That Move the Needle Most

**1. Partition design is your biggest single lever (easily 100–200x query latency difference).**

Partition your events table by `day(occurred_at), tenant_id`. This means any query filtering by time range OR tenant ID skips most of the table. Without partitioning, a dashboard showing "acme's activity last week" scans 500M rows every load. With it, Trino reads ~1% of the files. This changes a 30-second query to 3 seconds and slashes Trino's daily CPU load by 80–90%.

Get this right before loading data. Iceberg supports partition evolution (you can change it later without rewriting files), but changing it after 6 months of accumulated data is a painful migration.

**2. Pre-aggregate dashboards that run frequently.**

A nightly dbt model that pre-aggregates "weekly active users by tenant" turns a 20-second dashboard query into 200 ms. You run the expensive aggregation once at night; dashboards query the tiny rollup table. Often reduces Trino's total daily compute 80–90% for steady-state operations.

Pick your 3–5 most-hit dashboards and build rollups for them first. The long-tail of ad-hoc queries can still hit the raw table — that's fine.

**3. Don't stream; batch-ingest every 1–6 hours.**

Micro-batching (Spark job every 1–6 hours) is 100x less operationally complex than real-time streaming to Iceberg, compacts naturally, and gives you 1–6 hour freshness — which is good enough for virtually all SaaS analytics use cases (very few customers actually need sub-minute latency on their analytics dashboard).

Streaming ingestion to Iceberg is the #1 way to create millions of tiny files, which Trino then spends all its time opening instead of reading. It also dramatically increases the complexity of your compaction job and CDC pipeline. Don't build it until customers explicitly require it and pay for the engineering cost.

## Rough Cost Estimate for Your Situation

| Item | Annual Cost |
|---|---|
| Storage on already-provisioned MinIO | ~$0 incremental ($100–200/yr if adding disks) |
| Compute (on already-provisioned k8s cluster) | $0 cash / ~$16k/yr if charging back at $0.03/vCPU-hr |
| Engineering FTE (ingestion + compaction + on-call) | **$100k–$200k/yr** (0.5–1.0 FTE) |
| **Total on-prem, already-provisioned hardware** | **~$100k–$200k/yr**, almost entirely engineering |

Managed Snowflake for comparison: ~$5k/yr compute + ~$60k–100k/yr in reduced FTE = roughly equivalent total cost, with the delta depending on whether you can actually redeploy that FTE.

## The Honest Answer to Your Question

Architectural decisions matter enormously, but not in the way you hoped. They don't make the system cheap — they prevent it from becoming catastrophically expensive. The difference:

- **Right partition spec + rollup tables + batch ingestion** → engineering cost stays at 0.5 FTE, queries run in seconds, you feel good about it
- **Wrong partition spec + no rollups + streaming ingestion + no compaction automation** → engineering cost balloons to 1.5–2.0 FTE, queries run in minutes, you regret it

Cost mostly tracks with tenant count (more ingestion work) and query volume (more cluster capacity). But partition design, rollup discipline, and compaction automation prevent the engineering overhead from compounding as you grow.
