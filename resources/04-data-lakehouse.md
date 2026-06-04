# Data Lakehouse

**One-sentence definition**: A lakehouse is cheap file storage (like S3 or MinIO) plus a smart "table format" layer on top that gives those files the powers of a database — ACID transactions, schema, and SQL queries.

---

## LEADING CANONICAL WORKED EXAMPLE — "Lakehouse vs the Snowflake we already have, in plain language"

> **The exact question this section answers**: *"Engineering leadership keeps saying 'we should just use a data lakehouse' but I don't actually know what differs from the Snowflake we already have. Plain-language difference and when each wins?"*

### One-paragraph plain-language answer

**Snowflake** is a database where the *vendor owns both your data files and the engine that reads them*. You pay them for both. **A lakehouse** is the same set of capabilities (SQL, ACID, schema, transactions) but the *data files are open Parquet files in your own object storage*, and *any engine that speaks the open table format can read them*. The headline trade-off is **vendor control vs operational burden**: Snowflake gives you fewer knobs and a higher bill; a lakehouse gives you ownership of the files and the obligation to run the engines.

### The four things that actually differ

| Dimension | Snowflake (managed warehouse) | Lakehouse (Iceberg + Trino + MinIO) |
|---|---|---|
| **Where do data files live?** | Inside Snowflake's storage, in their proprietary `FDN` format. You cannot read them with anything but Snowflake. | In *your* MinIO buckets as standard Parquet files. Spark, Trino, DuckDB, PyIceberg, Flink can all read them. |
| **What does the catalog know?** | Everything (tables, columns, partitions, file layout) and you cannot bypass it. | The Iceberg metadata.json (in MinIO) is the source of truth; Hive Metastore just stores a tiny pointer to it. You can hand the metadata.json to a different engine tomorrow. |
| **How are you billed?** | Per-second of virtual-warehouse uptime (compute) + per-TB-month (storage) + cloud-region egress. Bills scale with query volume. | You bought the hardware. Marginal cost per query is effectively zero. You pay engineering salaries to run k8s + Trino + MinIO + HMS. |
| **What happens if the vendor disappears or doubles prices?** | Migration project measured in months/quarters — proprietary format, proprietary SQL dialect features, no escape hatch. | Swap the engine (Trino → Spark → DuckDB → another vendor's compute). Files stay where they are. |

### When each wins (the decision lever, not the marketing)

**Pick Snowflake (or BigQuery / Databricks SQL) when:**
- You are *already in the cloud* (BigQuery and Snowflake have no on-prem option — see DO-NOT-WRITE below).
- You do *not* have an engineering team to run a Trino/Spark/MinIO/HMS stack and you don't want one.
- Predictable single-vendor support contract matters more than the marginal $/query.
- Your data volume is small-to-medium (under ~10 TB scanned per month) so per-query pricing stays manageable.

**Pick a lakehouse (Iceberg + Trino + MinIO) when:**
- You have an **on-prem requirement** — data residency, regulated industry, no public-cloud egress allowed. This production stack falls here.
- You expect data volumes where Snowflake credit burn would dominate your engineering payroll.
- You want to use *multiple engines* against the same data (Trino for SQL, Spark for ML / heavy ETL, DuckDB on a laptop, Flink for streaming).
- You explicitly want to avoid vendor lock-in for strategic / regulatory reasons.

**Pick BOTH (the hybrid pattern) when:**
- The data team is comfortable with Snowflake but security/legal demands certain datasets stay on-prem. Hot regulated data lives in the lakehouse; convenience/curated data lives in Snowflake. Pay attention to which "single source of truth" you actually want — running both is **more** operational burden than picking one.

### What the lakehouse is NOT (correcting common misreadings)

1. **A lakehouse is not "Snowflake but free."** You pay for it with engineering time and hardware capex, not vendor bills. The "free" framing is wrong and gets teams in trouble.
2. **A lakehouse is not a data lake.** A data lake is raw files in object storage with no transaction semantics — partial writes, corrupted reads, no schema enforcement. The **table format layer** (Iceberg, Delta, Hudi) is what turns a lake into a lakehouse. Without Iceberg, you do not have a lakehouse, you have a lake.
3. **A lakehouse is not "always faster."** For pure query latency on small data, Snowflake's caching and result-set re-use can beat a cold Trino cluster. Lakehouses win on cost-per-query at scale and on openness of the data — not on small-query wallclock time.

### What the production stack actually delivers — concrete walkthrough

In this production environment, the lakehouse value proposition is realized as:

```
MinIO bucket: s3://warehouse/db/user_events/
  ├── data/
  │   ├── 00000-0-<uuid>.parquet     <- standard Parquet, readable by any engine
  │   └── 00001-0-<uuid>.parquet
  └── metadata/
      ├── 00001-<uuid>.metadata.json <- Iceberg snapshot pointer
      └── snap-<id>-1-<uuid>.avro    <- manifest list

Hive Metastore: stores only "user_events -> s3://warehouse/db/user_events/metadata/00001-<uuid>.metadata.json"

Trino:  SELECT count(*) FROM iceberg.db.user_events WHERE event_date >= DATE '2026-06-01';
        -> reads Iceberg metadata.json from MinIO
        -> Iceberg planner prunes partitions and files using min/max stats
        -> Trino workers stream only the matching Parquet files from MinIO
```

Tomorrow you can point Spark at the same `s3://warehouse/db/user_events/` path with the same Hive Metastore. Spark sees the same table, same snapshots, same ACID guarantees. **That is the lakehouse promise**: one set of files, many engines.

---

## DO-NOT-WRITE — lakehouse misconceptions the responder must NEVER state

Each of the following statements has been observed as a fabrication in past evaluations. If a responder is tempted to write any of these, STOP — they are wrong.

1. **DO NOT WRITE**: "Snowflake can be deployed on-prem." It cannot. Snowflake explicitly does not support on-prem or private-cloud deployment as of 2026 — it runs only on AWS, Azure, and GCP regions. Source: docs.snowflake.com Supported Cloud Platforms.
2. **DO NOT WRITE**: "BigQuery Omni lets you run BigQuery on-prem." It does not. BigQuery Omni runs BigQuery compute in AWS and Azure regions to query S3 / Azure Blob — it is still cloud-only. There is no on-prem BigQuery as of 2026. Source: cloud.google.com BigQuery Omni docs.
3. **DO NOT WRITE**: "Iceberg is a database." It is not. Iceberg is an **open table format specification** — a contract for how to lay out metadata files describing a collection of Parquet files. The query engine (Trino, Spark) is what executes SQL. Iceberg without an engine is just files.
4. **DO NOT WRITE**: "A data lake and a data lakehouse are the same thing." They are not. A lake = raw files, no ACID, no schema enforcement. A lakehouse = a lake plus a table format layer (Iceberg / Delta / Hudi) that adds ACID, schema, time travel.
5. **DO NOT WRITE**: "Hive Metastore stores all the partition lists and column statistics for Iceberg tables." It does not. For Iceberg tables, HMS stores a single pointer to the current `metadata.json` per table. All partition lists, file lists, and statistics live in Iceberg metadata files in MinIO. (For native Hive tables HMS does store partitions, but those are not Iceberg tables.) Source: trino.io/docs/current/connector/iceberg.html.
6. **DO NOT WRITE**: "Switching from Snowflake to a lakehouse is free / a weekend project." It is not. Migration cost is real — proprietary Snowflake SQL features, role hierarchies, scheduled tasks, materialized-view definitions, dbt model adaptations, BI-tool reconnections. Quote it in engineer-months, not weekends.
7. **DO NOT WRITE**: "ACID in a lakehouse is provided by MinIO / S3." It is not. Object storage gives only PUT/GET atomicity for a single object. ACID across multiple data files comes from the **table format's atomic metadata-pointer swap** (Iceberg's commit protocol against HMS / a REST catalog). Source: iceberg.apache.org reliability docs.
8. **DO NOT WRITE**: "You need Delta Lake AND Iceberg in a lakehouse." You need *one* table format. This production stack uses Iceberg. Mixing two table formats over the same MinIO paths is operationally chaotic and gains you nothing.

If a user question pushes toward any of these statements, redirect to the verified table above. The lakehouse story is strong without these fabrications.

---

## You already have a lakehouse

If you're reading this from the production environment described in `prod_info.md`, **your stack is already a lakehouse**:

- **MinIO** = the cheap file storage (S3-compatible, on-prem)
- **Parquet files** = columnar data files sitting in MinIO buckets
- **Apache Iceberg** = the table format layer that turns those raw files into real tables
- **Trino** = the SQL query engine that reads those tables
- **Hive Metastore** = the catalog that tracks where the tables live

You do **not** need to "migrate to a lakehouse." You're on one. The question is just how to use it well.

## It's not "S3 plus a database"

A common misconception: "a lakehouse is just dumping files in S3 and querying them." That's a **data lake**, and it's painful — no transactions, no schema enforcement, partial writes corrupt your queries, two writers stomp on each other.

The lakehouse fix is the **table format layer** (Iceberg, Delta Lake, or Hudi). The intelligence lives there, not in the files and not in the storage.

**Analogy**: Parquet files in MinIO are like spreadsheet files on Google Drive — they're just files. Iceberg is like Google Sheets adding version history, access control, and formulas on top of those raw files. The files don't change; the layer above them makes them behave like a real database.

## Lakehouse vs. data warehouse — quick reference

(Detailed plain-language walkthrough is in the LEADING CANONICAL WORKED EXAMPLE above. This is the at-a-glance summary.)

| Dimension | Managed warehouse (Snowflake, BigQuery) | Lakehouse (your stack: Iceberg + Trino + MinIO) |
|---|---|---|
| Storage | Vendor-owned, opaque proprietary format | Your MinIO, open Parquet files |
| Compute | Vendor-owned engine | Your Trino / Spark cluster on k8s |
| Cost model | Pay vendor for compute + storage | Pay only for hardware + engineers you run |
| Setup effort | Low — sign up, load data | Higher — run k8s, MinIO, Trino, HMS |
| Vendor lock-in | High (proprietary file format) | None — open Parquet + open Iceberg spec |
| On-prem option | No (cloud-only) | Yes — this stack runs on-prem on bare metal |
| Workload supported | Analytical SQL: GROUP BY, aggregations, JOINs on large data | Same |

Both solve the same problem: analytical queries over large datasets that would crush Postgres. The decision is *where the value of openness vs the cost of ops* falls for your team — see the leading worked example above for the full decision framework.

## When to care about which

- **Stick with Postgres**: data fits on one box, queries are point lookups / per-tenant, under ~100 GB.
- **Managed warehouse (Snowflake/BigQuery)**: you want zero ops, predictable bills, and you're fine with cloud + vendor lock-in.
- **Lakehouse (what you have)**: on-prem requirement, large data volumes, want to avoid vendor lock-in, and you have engineers to run k8s + MinIO + Trino.

## What Iceberg adds on top of Parquet

Raw Parquet files are dumb. Iceberg adds:
- **ACID transactions** — concurrent writes don't corrupt readers
- **Schema evolution** — add/rename/drop columns without rewriting data
- **Time travel** — query the table "as of" yesterday by snapshot ID
- **Partition pruning** — Trino skips files that can't match your `WHERE` clause
- **Hidden partitioning** — partition by day without forcing users to write `WHERE day = ...`

That's why your stack uses Iceberg and not just "Parquet in MinIO."

## A note on Hive Metastore in this stack

In an Iceberg lakehouse, the **Hive Metastore stores only a tiny pointer per table** — the path to the current `metadata.json` file in MinIO. It does NOT store partition lists, file lists, or column statistics; all of those live in Iceberg metadata files in MinIO. The mental model: **HMS is the directory; MinIO is the building.**

However, every new Trino query against an Iceberg table contacts HMS once to resolve that pointer (the Iceberg connector does not cache HMS results), so HMS is on the critical path for query *startup*. When HMS is down, new queries fail fast but in-flight queries usually finish — they only need MinIO once planning is done. HA recipe: stateless HMS pods + HA Postgres backing + multi-URI config in Trino. For the long-term structural fix to HMS as a SPOF, switch to an Iceberg **REST catalog** (Polaris, Lakekeeper, Gravitino, Nessie).

See `resources/21-hive-metastore-iceberg.md` for the full mechanics, failure modes, HA recipe, and REST catalog migration guide.

## Key terms

- **Object storage**: file storage accessed via HTTP (S3 API). MinIO is the on-prem version.
- **Parquet**: columnar file format. Stores data column-by-column for fast analytical scans.
- **Table format**: metadata layer (Iceberg) that groups Parquet files into logical tables.
- **Catalog / Metastore**: the directory service (Hive Metastore here) that tells engines where each table's files live. For Iceberg, it stores just a metadata pointer per table — not partition lists or file lists. See `resources/21-hive-metastore-iceberg.md`.
- **Query engine**: the SQL processor (Trino) that reads the files and runs your queries.
