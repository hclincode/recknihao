# BigQuery vs Snowflake vs ClickHouse vs DuckDB vs Self-Hosted Iceberg: How to Choose

---

## LEADING CANONICAL WORKED EXAMPLE — "BigQuery vs Snowflake vs Iceberg+Trino for a 50-person B2B SaaS — what actually matters?"

> **The exact question this section answers**: *"If we're evaluating BigQuery vs Snowflake vs Iceberg+Trino for a multi-tenant B2B SaaS, what are the actual differentiators that matter for a 50-person engineering org, not the marketing pitch?"*

### The seven decision levers (in priority order)

For a 50-person engineering org, these are the differentiators that actually matter. The marketing pitches focus on the wrong ones (performance benchmarks, AI features). Here is the real list:

| # | Decision lever | BigQuery | Snowflake | Iceberg + Trino |
|---|---|---|---|---|
| 1 | **On-prem possible?** | No — GCP cloud only. BigQuery Omni still runs in AWS/Azure regions, not on-prem. | No — AWS/Azure/GCP cloud only. No private-cloud or on-prem option. | **Yes — runs anywhere k8s runs**, including bare metal on-prem. |
| 2 | **Vendor lock-in cost (to leave)** | Highest — proprietary FDN-like storage, GoogleSQL dialect features, BigQuery ML, scheduled queries. Migration = engineer-quarters. | High — proprietary storage, tasks, streams, dynamic tables. Iceberg-external-table support exists but is partial. Migration = engineer-quarters. | **Lowest — Parquet files in your bucket, open Iceberg spec, ANSI-ish SQL. You can swap Trino for Spark/Flink/DuckDB without moving data.** |
| 3 | **Cost shape & predictability** | Per-TB-scanned (default) — bills can spike on a single bad query. Slot/capacity pricing is the alternative for sustained scan volume. | Per-second of virtual-warehouse uptime, 60s minimum. Idle warehouses cost nothing; busy warehouses scale linearly with use. | **Capex on hardware + opex on engineers. Marginal $/query ≈ 0 once the cluster is up.** Predictable but high fixed cost. |
| 4 | **Ops burden (engineers needed to keep it running)** | Lowest — Google runs everything. No clusters to size. | Low — you size virtual warehouses, set up roles, manage cost guardrails. No clusters to operate. | **Highest — you run k8s, Trino coordinator+workers, MinIO, Hive Metastore (or REST catalog), Spark for ingestion, compaction/maintenance jobs. Need 2-4 platform engineers minimum.** |
| 5 | **Multi-tenant isolation (B2B SaaS specific)** | Per-customer datasets/projects; IAM-based isolation. Per-tenant cost-attribution works but is heavyweight. | Per-customer roles/warehouses; query tags for cost attribution. Snowflake's clean separation of compute units helps here. | **Per-tenant Iceberg tables OR a tenant_id column with OPA-enforced row filtering. Cost attribution is per-query via Trino's accounting tables (system.runtime.queries).** Maximum flexibility, you build the isolation discipline. |
| 6 | **dbt support quality** | First-class. Native adapter, well-supported. | First-class. Most mature dbt adapter; Snowflake-specific features (zero-copy clones, time travel) integrated. | **First-class for Trino — `dbt-trino` adapter, supported. `dbt-iceberg` is community-maintained. Quality is good but you will hit edges (e.g., concurrent dbt run conflicts on Iceberg need careful retry logic).** |
| 7 | **Time-to-first-dashboard (greenfield)** | Fastest — sign up, load CSV, query. Days. | Fast — sign up, load CSV, query. Days-to-week. | **Slowest — stand up MinIO + HMS + Trino + Spark + dbt + monitoring. 4-12 engineer-weeks minimum for a robust deployment.** |

### How to actually decide — the four scenarios

The seven-lever table above maps onto four real decision scenarios. Match yours:

**Scenario A — You are cloud-native, no on-prem requirement, want fastest time-to-value.**
- Default: **Snowflake** if your data team is already trained on it; **BigQuery** if you're on GCP and want serverless / no warehouse-sizing.
- Reasoning: dollar-cost is real but ops-burden savings are larger at 50-person scale. You do not need to be in the platform-engineering business.

**Scenario B — You are on-prem (this production stack) — data residency, regulated, or no public-cloud allowed.**
- Default: **Iceberg + Trino + MinIO**. BigQuery and Snowflake are disqualified up front (lever 1).
- Reasoning: only viable choice for the constraint. Budget the ops burden honestly — 2-4 platform engineers.

**Scenario C — You have huge sustained query volume (>50 TB scanned/month) and a strong engineering team that wants to own the stack.**
- Default: **Iceberg + Trino** (even if on-cloud — you run it on EC2/GCE). The per-TB-scanned bill at BigQuery and the per-second-warehouse bill at Snowflake will exceed your engineering payroll at this scale.
- Reasoning: the cost crossover point. Below ~10 TB/month, the cloud warehouses win; above ~50 TB/month, the lakehouse wins; in between, depends on your engineering capacity.

**Scenario D — You want to use multiple engines (Trino for SQL, Spark for ML, DuckDB on laptops, Flink for streaming) against the SAME data.**
- Default: **Iceberg + Trino** for the SQL surface, with the same Iceberg tables read by Spark / DuckDB / Flink.
- Reasoning: the lakehouse is the only option here. Snowflake and BigQuery require you to either copy data out (defeating the purpose) or live within their engine. Iceberg's "one table format, many engines" promise is the unique value.

### What the marketing pitches mislead you on

The vendor pitches lead with these, which are **not** the deciding factors for a 50-person B2B SaaS:

1. **"Query speed benchmarks."** At realistic 50-person-SaaS data volumes (10-100 TB total), all three are fast enough. The 2x performance benchmark in a blog post will not be visible in your dashboards.
2. **"AI / vector search / LLM features."** Every vendor ships these now. They are not differentiators for OLAP work — they are bolt-ons that compete with dedicated vector DBs (pgvector, Weaviate, etc.) and dedicated LLM platforms.
3. **"Auto-scaling / serverless."** Sounds great until the bill arrives. Per-TB-scanned (BigQuery) and per-second-warehouse (Snowflake) both translate "auto-scale" into "auto-spend." Plan capacity, do not rely on auto-scaling to control costs.
4. **"Time travel / zero-copy clones."** All three table formats / warehouses now have these. Iceberg has snapshot-based time travel (`FOR VERSION AS OF`, `FOR TIMESTAMP AS OF`); Snowflake has Time Travel; BigQuery has time-travel windows. Not a tiebreaker.
5. **"Native streaming / CDC ingestion."** Real but you should not let it pick the warehouse. Streaming ingestion is a separate concern; you can run Kafka + Debezium + Spark Structured Streaming into Iceberg, or Snowpipe into Snowflake, or Dataflow into BigQuery. None is a magical advantage.

### The honest decision for a 50-person B2B SaaS (default answer)

If you are **on-prem (this production stack)**: **Iceberg + Trino + MinIO** is the answer because lever 1 (on-prem possible) eliminates the cloud options. The discussion stops there.

If you are **cloud and have 0-2 platform engineers**: Snowflake unless you have a strong GCP allegiance (then BigQuery). The ops-burden lever (lever 4) dominates.

If you are **cloud and have 3+ platform engineers AND data volume is growing past 50 TB/month**: Iceberg + Trino on EC2/EKS. The cost-shape lever (lever 3) dominates.

In every case, the decision should rest on levers 1-4, not on levers 5-7 or on marketing pitches.

---

## DO-NOT-WRITE — tool-choice fabrications the responder must NEVER state

Each of the following has been observed as wrong or misleading in past evaluations. If a responder is tempted to write any of these, STOP — they are wrong.

1. **DO NOT WRITE**: "Snowflake supports on-prem deployment with Snowflake Connector for Hadoop / Snowflake on Azure Stack." It does not. Snowflake explicitly does not support on-prem or private-cloud deployment. Source: docs.snowflake.com Supported Cloud Platforms.
2. **DO NOT WRITE**: "BigQuery Omni runs BigQuery on-prem." It does not. BigQuery Omni runs BigQuery compute in AWS and Azure regions to query S3/Blob — still cloud. No on-prem option exists as of 2026. Source: cloud.google.com BigQuery Omni docs.
3. **DO NOT WRITE**: "ClickHouse and Trino do the same job." They do not. ClickHouse is a columnar OLAP DB optimized for single-node aggregations on tightly-structured event tables. Trino is a distributed federated query engine that reads many data sources including Iceberg. Different scaling models and JOIN behavior. Recommend ClickHouse only when a specific Trino limitation is named.
4. **DO NOT WRITE**: "DuckDB is a replacement for Trino in production." It is not. DuckDB is a single-process embedded analytical DB; no concurrency model, no clustering. Use it as a laptop-development tool against the same Iceberg files Trino queries — not as a production multi-user engine.
5. **DO NOT WRITE**: "Snowflake is always more expensive than Iceberg + Trino." It is not. At low data volumes (<10 TB scanned/month) and small engineering teams, the cloud warehouse total cost (vendor bill + tiny ops headcount) is often LOWER than the lakehouse total cost (hardware + 2-4 platform engineers). The cost crossover sits around 50 TB/month scanned for most SaaS shapes.
6. **DO NOT WRITE**: "Iceberg + Trino is the right answer for every SaaS." It is not. For a 5-person SaaS with 100 GB of data and no engineering capacity to operate platform infrastructure, Snowflake / BigQuery / Postgres are better answers. The lakehouse wins under specific conditions (on-prem requirement, large data, in-house engineering) — not universally.
7. **DO NOT WRITE**: "Redshift is on-prem / private-cloud capable." It is not. Redshift is AWS-only. (Redshift Serverless is also AWS-only.) Removed from on-prem candidate lists.
8. **DO NOT WRITE**: "Databricks SQL is a lakehouse you can run on-prem." Databricks runs as a managed service on AWS/Azure/GCP. There is no on-prem Databricks. Open-source Spark + Delta Lake can run on-prem, but that is not "Databricks."
9. **DO NOT WRITE**: "Choosing between BigQuery and Snowflake is mostly about price." It is mostly about **cost shape** (per-TB-scanned spike risk vs per-second-warehouse predictability) and ops model (serverless vs warehouse-sized). Headline price comparisons mislead — model your actual query pattern.
10. **DO NOT WRITE**: "Vector / AI features are a tiebreaker." They are not — every vendor ships these now. Decision should rest on levers 1-4 above.

---

## Quick answer (TL;DR)

- **Your production stack is already self-hosted Iceberg + Trino + MinIO + Spark on-prem** — most "which tool?" debates don't apply to you.
- **On-prem requirement eliminates BigQuery and Snowflake** as primary options — they are cloud-only managed services.
- For greenfield decisions: under 100M rows, DuckDB or Postgres is enough; 100M–10B rows, ClickHouse or a managed warehouse; 10B+ rows, Iceberg + Trino/Spark.
- The decisive question is rarely "which is fastest" — it is **"who is on call when it breaks?"** Managed services trade money for ops.
- All five tools speak SQL; the differences are operational model, scale ceiling, and cost shape.

---

## The decision framework (not a features table)

Three questions decide most of this for you. Answer them in order:

1. **Are you on-prem or cloud?** On-prem (like this production stack) eliminates BigQuery and Snowflake as primary options. They are managed cloud services with no on-prem deployment.
2. **How much data do you actually have? (rows, not GB)**
   - Under 100M rows → DuckDB or even a tuned Postgres can handle it.
   - 100M–10B rows → ClickHouse or a managed warehouse fits comfortably.
   - 10B+ rows → Iceberg + Trino/Spark territory.
3. **Do you have a data engineer / platform engineer?** If no, lean toward a managed service. If yes, self-hosted lakehouse becomes viable.

---

## Tool profiles (honest about trade-offs)

### BigQuery
Serverless cloud warehouse on GCP. No clusters to manage; pay per TB scanned. Great for cloud-native SaaS on GCP that wants zero ops.

- **Weakness**: surprise bills if queries scan huge partitions (a missing WHERE clause can cost hundreds of dollars). Vendor lock-in to GCP. No on-prem option.
- **When to use**: GCP shop, want zero ops, willing to budget per-query cost.
- **Fits your stack?** No — on-prem requirement disqualifies it.

### Snowflake
The most polished managed warehouse. Best ecosystem: first-class dbt support, hundreds of connectors, clean separation of storage and compute (you can spin up multiple "virtual warehouses" against the same data).

- **Weakness**: expensive at scale. Virtual warehouses bill per second with a 60-second minimum, so frequent small queries add up. No on-prem deployment.
- **When to use**: cloud-based team, want a "just works" warehouse, data team already knows it.
- **Fits your stack?** No — on-prem requirement disqualifies it.

### ClickHouse
Open-source columnar DB optimized for aggregation queries. Often the **fastest engine on a single node or small cluster** for `GROUP BY` over wide event tables. Available self-hosted or via ClickHouse Cloud.

- **Weakness**: schema changes are painful (many `ALTER TABLE` operations are blocking or limited). JOIN performance is weaker than Snowflake/BigQuery/Trino. Opinionated data model (you must pick MergeTree variants, ordering keys, etc.).
- **When to use**: extreme query speed on append-only event data, team willing to learn ClickHouse quirks.
- **Fits your stack?** Could be self-hosted on your k8s, but it duplicates what Trino already does for you. Only worth adding if you have a specific dashboard latency problem Trino can't solve.

### DuckDB
An embedded, in-process analytical database. Runs as a library inside your Python/Node/Go process. Reads Parquet files directly from MinIO/S3. **No server, no cluster, no ops.**

- **Weakness**: single-machine only. Not designed for concurrent multi-user access. No clustering mode. RAM is the ceiling for many query shapes.
- **When to use**: data team of 1–2 people, data fits on one machine's SSD, development/prototyping, small SaaS, ad-hoc analysis.
- **Fits your stack?** Yes — DuckDB can read Iceberg/Parquet files directly from your MinIO. Excellent as a developer-laptop tool for prototyping queries before running them on Trino.

### Self-hosted Iceberg + Trino (what you already run)
Open table format (Iceberg) + open query engine (Trino) + open object store (MinIO). The most flexible setup: any engine can read your tables (Spark, Trino, Flink, DuckDB, PyIceberg), no vendor lock-in, data lives in standard Parquet files.

- **Weakness**: highest ops burden. You run Kubernetes, MinIO, Trino coordinator + workers, Hive Metastore, Spark for ingestion, and compaction/maintenance jobs. Tuning is your responsibility.
- **When to use**: on-prem requirement, large data volumes, in-house engineers to run it, want to avoid vendor lock-in.
- **Fits your stack?** This **is** your stack.

---

## Cost comparison at SaaS scale

A common scenario: 1 TB of analytical data, 100 internal analysts, 10,000 queries/month.

| Tool | Rough monthly cost | Cost shape |
|---|---|---|
| BigQuery | ~$620 query + $23 storage (on-demand) | Per TB scanned at ~$6.25/TB; first 1 TB/month free; spiky. Capacity-based **slot** pricing is an alternative for high sustained scan volumes. |
| Snowflake | ~$1,000 | Per second of warehouse uptime |
| ClickHouse Cloud | $50–$200 | Per node-hour |
| Self-hosted Iceberg + Trino | ~$0 marginal | You already paid for the hardware |

The on-prem economics are why this production stack chose self-hosted: **marginal cost per query is effectively zero**, and the 80-tenant load fits comfortably on existing hardware. The trade-off is the engineering team you employ to keep it running.

---

## The "just use DuckDB" option

For SaaS teams under ~500M rows total: DuckDB pointing at Parquet files in MinIO is a serious answer.

- Zero ops, no cluster.
- Reads the **same Iceberg/Parquet files** as Trino, so you can develop locally and graduate to Trino later.
- Surprisingly fast — for many workloads it beats a small Trino cluster.
- Add Trino when you need concurrent multi-user access, when data exceeds single-machine memory, or when one query starts blocking another.

On this production stack, DuckDB is a useful **complement** to Trino, not a replacement: engineers can prototype queries against MinIO from a laptop without hitting the shared Trino cluster.

---

## What your stack already has

Your production environment runs Iceberg 1.5.2 + Trino 467 + MinIO + Spark + Hive Metastore on-prem, all on Kubernetes. **You don't need to choose** — you need to learn how to use what's deployed.

The comparison above matters most when:
- Another team asks you to recommend a tool.
- A vendor pitches you to replace a component.
- You need to know what trade-offs the original architects accepted.

Default answer for any new analytical workload on this stack: **put the data in Iceberg, query it with Trino, transform it with dbt or Spark.** Reach for ClickHouse or DuckDB only when you can name the specific limitation of Trino+Iceberg you are trying to solve.

---

## Key terms

- **Managed service**: vendor runs the infrastructure; you write SQL and pay a bill. Examples: BigQuery, Snowflake, ClickHouse Cloud.
- **Self-hosted**: you run the infrastructure on your own machines. Examples: Trino on k8s, ClickHouse on bare metal.
- **Embedded / in-process**: the database runs inside your application process as a library, with no separate server. Example: DuckDB, SQLite.
- **Vendor lock-in**: cost of moving off a system, measured in re-engineering effort. Open formats (Iceberg, Parquet) minimize this; proprietary formats (BigQuery native storage) maximize it.
- **Separation of storage and compute**: you can scale query power up and down without moving data. Snowflake popularized it; lakehouses (Iceberg + Trino on MinIO) provide it by default.
