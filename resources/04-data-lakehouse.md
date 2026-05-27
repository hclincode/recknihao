# Data Lakehouse

**One-sentence definition**: A lakehouse is cheap file storage (like S3 or MinIO) plus a smart "table format" layer on top that gives those files the powers of a database — ACID transactions, schema, and SQL queries.

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

## Lakehouse vs. data warehouse

| | Managed warehouse (Snowflake, BigQuery) | Lakehouse (your stack) |
|---|---|---|
| Storage | Vendor-owned, opaque | Your MinIO, open Parquet files |
| Compute | Vendor-owned | Your Trino / Spark cluster |
| Cost model | Pay vendor for both compute + storage | Pay only for hardware you run |
| Setup effort | Low — sign up, load data | Higher — run k8s, MinIO, Trino |
| Vendor lock-in | High | None — files are open formats |
| Workload | Same: analytical SQL, GROUP BY, aggregations on large data |

Both solve the same problem: analytical queries over large datasets that would crush Postgres.

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
