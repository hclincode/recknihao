# BigQuery vs Snowflake vs ClickHouse vs DuckDB vs Self-Hosted Iceberg: How to Choose

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
| BigQuery | ~$250 query + $23 storage | Per TB scanned; spiky |
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
