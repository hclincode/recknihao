# From OLTP to OLAP: The Mental Model Shift for SaaS Engineers

> Your CTO just said "set up the lakehouse for analytics." You know Postgres. You know Rails/Django/Node. You have never written a Spark job. This guide bridges that gap.
>
> Production stack assumed: Spark + Iceberg 1.5.2 + MinIO + Hive Metastore + Trino 467, all on Kubernetes on-prem.

---

## TL;DR

- Your Postgres skills transfer about 30%. SQL is the same; almost everything else flips.
- Stop normalizing. Stop indexing every FK. Stop expecting milliseconds. Stop UPDATEing rows.
- Lakehouse = a *copy* of your Postgres data, reshaped for big scans.
- Design tables as wide, denormalized, append-only, date-partitioned facts.
- Day 1 goal: get one table from Postgres into Iceberg, partitioned by day, queryable from Trino.

---

## The one-sentence difference

**Your Postgres database is optimized to answer questions about ONE thing fast. Your lakehouse is optimized to answer questions about ALL things fast.**

A point lookup (`WHERE id = 123`) is what Postgres lives for. A scan-and-aggregate (`GROUP BY plan_type`) over 2 billion rows is what the lakehouse lives for. Different problem, different machine.

---

## Side-by-side: everything you know vs. what changes

| What you know (OLTP / Postgres) | What changes (OLAP / Iceberg + Trino) | Why |
|---|---|---|
| Normalize to 3NF, use foreign keys | Denormalize — copy columns into the fact table | JOINs across billions of rows are slow; pre-joining at write time is cheaper |
| INSERT / UPDATE / DELETE all day | Mostly INSERT (append); UPDATE / DELETE are rare and expensive | Parquet files are immutable; mutations rewrite files |
| Index every foreign key | Partition by `day(event_ts)` and `tenant_id`; no row-level indexes | Analytical queries scan ranges, not point lookups. Partition pruning replaces indexes |
| `SELECT * FROM users WHERE id = 123` | `SELECT plan_type, COUNT(*) FROM events GROUP BY plan_type` | Different access pattern entirely — row vs column scan |
| Schema = many small normalized tables | Schema = a few wide fact tables + small dimension tables (star schema) | Fewer JOINs = faster aggregations |
| Latency goal: < 10 ms | Latency goal: < 10 s for dashboards, < 60 s for heavy analysis | Workload is "scan a lot," not "fetch one row" |
| Row-level ACID transactions | Snapshot isolation at the *table* level (Iceberg) | Iceberg gives atomic commits per table, not per row |
| ORM (ActiveRecord, Sequelize, SQLAlchemy) | Raw SQL via Trino — no ORM | Analytical SQL (windows, CUBE, ROLLUP) is too complex for ORMs |
| `ALTER TABLE ADD COLUMN` is a scary migration | Iceberg schema evolution is instant and metadata-only | Iceberg tracks column IDs; existing Parquet files aren't rewritten |
| Production DB = source of truth | Lakehouse = **copy** of truth, sourced from Postgres | Never run analytics directly on prod Postgres |
| Real-time data, always fresh | Near-real-time at best — minutes to hours of lag | Batch ETL introduces lag; that's the trade-off |
| Row-level permissions in the app layer | Schema/view-level grants in Trino, per-tenant views | Different isolation model — see `05-multi-tenant-analytics.md` |
| Connection pool (PgBouncer, 20 conns) | Trino handles concurrency; Spark jobs run as batch | Different runtime model entirely |
| Backup = `pg_dump` nightly | Snapshots are built in (Iceberg time travel) | Every commit is a queryable snapshot for ~7 days |

---

## The three biggest mental shifts

### 1. Stop thinking about rows, start thinking about columns

In Postgres, a row is stored together on disk. Reading one row is one disk seek. Reading one column out of 50 still pulls the whole row.

In Parquet (the file format under Iceberg), each column is stored separately. `SELECT plan_type, COUNT(*) FROM events` only reads the `plan_type` bytes — it never touches the other 49 columns. This is why a wide table with 80 columns is *fine* in OLAP and *bad* in OLTP.

Design implication: **wide tables with lots of columns are good**, because you only pay for the columns you SELECT.

### 2. Stop expecting milliseconds, start designing for seconds

Postgres returns a primary-key lookup in 1 ms. Trino over Iceberg returns a 100M-row aggregation in 3–15 seconds. That is *good* — you are scanning hundreds of millions of rows.

Design implication: dashboards load in 2–10 seconds, not 50 ms. If you need sub-second, pre-aggregate with a dbt model into a small summary table.

### 3. Stop mutating, start appending

In Postgres you `UPDATE users SET plan = 'pro'`. In a lakehouse, you append a new event row: `(user_id=123, event='plan_changed', new_plan='pro', ts=now())`. The current state is *derived* by taking the latest event per user.

Iceberg *does* support UPDATE/DELETE, but each one writes "delete files" that drag query performance until the next compaction. Treat mutations as a last resort.

Design implication: **event sourcing mindset**. Append-only fact tables. Compute current state with `ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY ts DESC)`.

---

## Day-1 checklist: setting up your first lakehouse table

Follow in order. Don't skip steps. **The most common mistake: skipping step 3 (Spark ingestion) and trying to query Postgres directly from Trino via the Postgres connector. It works, but it's slow and puts load on your production DB.**

1. **Pick your 2–3 most-queried analytical tables in Postgres.** For most SaaS, this is `events`, `orders` (or `subscriptions`), and `sessions`. Ignore everything else for now.
2. **Design the denormalized fact schema.** For each fact table, list the columns you need *and* the dimension columns you usually JOIN to (user plan, account region, signup date). Copy those in at ingest time so the fact row is self-contained.
3. **Write a Spark job** that reads from Postgres JDBC and writes an Iceberg table to MinIO via Hive Metastore. See `13-postgres-to-iceberg-ingestion.md` for the full template.
4. **Choose your partitions: `(day(event_ts), tenant_id)`** for B2B SaaS event tables. Date prunes time-range queries; tenant prunes single-customer queries.
5. **Schedule compaction from day one.** Run `CALL iceberg.system.rewrite_data_files('analytics.events')` nightly. Without this, you accumulate thousands of tiny files and queries crawl.
6. **Create per-tenant views in Trino** for tenant isolation. `CREATE VIEW tenant_42.events AS SELECT * FROM analytics.events WHERE tenant_id = 42;`
7. **Point your BI tool at Trino.** Trino speaks standard SQL via a JDBC driver — Metabase, Superset, Tableau all connect.

---

> ## STOP — Step 6 is NOT OPTIONAL for B2B SaaS
>
> If you are building a multi-tenant B2B product, **step 6 (per-tenant Trino views) is a hard requirement, not a nice-to-have.** Skipping it means any analyst, any BI user, or any compromised credential can run `SELECT * FROM analytics.events` and see every customer's data. This is a security incident, a contract violation, and (depending on your jurisdiction) a regulatory breach.
>
> **The non-skippable pattern:**
> ```sql
> CREATE VIEW tenant_42.events AS
>   SELECT * FROM analytics.events WHERE tenant_id = 42;
>
> GRANT SELECT ON tenant_42.events TO ROLE tenant_42_role;
> REVOKE ALL ON analytics.events FROM ROLE tenant_42_role;
> ```
>
> **Why this step is the one that gets dropped:** the first 5 steps "feel done" the moment dashboards show data, so engineers stop there. But "data shows up correctly when I query it as admin" is not the same as "data is isolated when a tenant or BI user queries it." Trino does **not** do per-tenant filtering automatically — there is no Postgres-row-level-security equivalent enabled by default. If you don't build the view + grant + revoke layer, every query runs against the raw fact table.
>
> If you're tempted to skip this with "we'll add it later" — don't. Adding it after dashboards are wired up means rewriting every dashboard's table reference. Build the per-tenant views first, point dashboards at `tenant_<id>.events` from day one. See `resources/05-multi-tenant-analytics.md` for the full isolation playbook and CI verification recipe.

---

## Common first mistakes

- **Running UPDATEs on Iceberg tables.** Technically supported, but every UPDATE writes a delete file. Queries get slower until compaction runs. Append, don't mutate.
- **Setting up Iceberg but still pointing dashboards at Postgres.** You did the work for nothing. Move the queries.
- **Forgetting compaction.** Spark writes one Parquet file per task. After 30 days you have 50,000 tiny files. Queries scan all of them. Schedule `rewrite_data_files` nightly from day one.
- **Over-denormalizing.** If you copy a user's current plan into every event row, you lose the ability to ask "what plan was this user on *at the time* of the event." Snapshot dimension values *at event time*, not the current value.
- **Treating the lakehouse like Postgres.** No FK constraints, no UNIQUE indexes, no auto-incrementing IDs. The lakehouse won't enforce them — your Spark job must.
- **Skipping `expire_snapshots`.** Iceberg keeps every old snapshot forever by default. Storage grows without bound. Run `expire_snapshots` weekly.

---

## Key terms

| Term | Plain meaning |
|---|---|
| **Lakehouse** | Object storage (MinIO) + table format (Iceberg) + query engine (Trino) — a warehouse-like system on top of cheap files |
| **Iceberg** | The table format that turns piles of Parquet files into ACID-transactional tables with schema evolution |
| **Parquet** | A columnar file format — stores each column separately for fast analytical reads |
| **Hive Metastore** | The catalog Iceberg uses to remember "table X lives at this path, has this schema, has these snapshots" |
| **Fact table** | A big, wide, append-only table of events/transactions (the *what happened*) |
| **Dimension table** | A small table of attributes (users, products, accounts) joined to facts |
| **Partition** | A physical subfolder on disk, like `event_ts_day=2026-05-23/`, that lets queries skip irrelevant data |
| **Compaction** | Merging many small Parquet files into fewer big ones (~128 MB) to keep queries fast |

---

## Summary

You are not learning a new database. You are learning a new *paradigm*: append-only, columnar, partitioned-by-date, denormalized, batch-loaded. SQL is the part that stays the same. Everything around it flips. Get one table flowing from Postgres into Iceberg with partitioning and nightly compaction — that's 80% of the conceptual leap done.
