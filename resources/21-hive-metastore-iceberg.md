# Hive Metastore in the Trino + Iceberg + MinIO Stack

> **Production stack reminder**: Iceberg 1.5.2 tables in MinIO, queried by Trino 467 with the Iceberg connector, with Hive Metastore (HMS) running in the on-prem k8s cluster as the catalog. Spark uses the same HMS for ingestion. This document explains what HMS actually does for **Iceberg** tables (which is much less than it does for legacy Hive tables), why it's on the critical path for every query, what happens when it fails, and how to make it HA — or eliminate it entirely with a REST catalog.

---

## The one-sentence mental model

**For Iceberg tables, HMS stores a tiny pointer — nothing more. All the real table information lives in MinIO.**

Specifically:

- **What HMS stores**: a row per Iceberg table whose only Iceberg-specific payload is the **path to the current `metadata.json` file** in MinIO. That's it — one S3 path string per table, plus a few generic columns like table name, database/schema name, owner, and creation timestamp.
- **What HMS does NOT store for Iceberg**: partition lists, file lists, column statistics, row counts, schema history, snapshots. All of these live in Iceberg's own metadata files (`metadata.json`, manifest lists, manifests) in MinIO.

This is the **biggest mental shift** when moving from legacy Hive tables to Iceberg. In a Hive-style table, HMS held the partition catalog — every `year=2024/month=03/day=15/` directory was registered as a row in HMS's `PARTITIONS` table, and queries had to fetch potentially millions of those rows to plan a scan. In an Iceberg table, HMS holds **one pointer per table**, and everything else lives in object storage. HMS is the directory; MinIO is the building.

### Visual: what's where

```
HIVE METASTORE (Postgres backend)
+----------------------------------------------------------+
|  TABLE: analytics.user_events                            |
|    metadata_location = s3a://lakehouse/analytics/        |
|                        user_events/metadata/             |
|                        00042-abc123.metadata.json        |
|  (and that's it — one pointer per table)                 |
+----------------------------------------------------------+
                            |
                            | resolves to
                            v
MINIO (s3a://lakehouse/analytics/user_events/)
+----------------------------------------------------------+
|  metadata/                                               |
|    00042-abc123.metadata.json   <-- current pointer here |
|    00041-...metadata.json       <-- previous snapshots   |
|    snap-...avro                 <-- snapshot manifest    |
|    ...avro                      <-- manifest files       |
|  data/                                                   |
|    day_occurred_at=2026-05-25/                           |
|      tenant_id=acme/                                     |
|        00000-0-...parquet  <-- ACTUAL DATA HERE          |
|        00001-0-...parquet                                |
|      tenant_id=globex/                                   |
|        ...                                               |
+----------------------------------------------------------+
```

Schema, partitions, file lists, per-file min/max stats, row counts — everything Trino needs to plan and execute a query — lives in the Iceberg metadata + manifest files in MinIO. HMS just tells you which `metadata.json` is the current one.

---

## Common myths about Hive Metastore + Iceberg — read FIRST (the load-bearing wrong claims)

> **Lead with the TRUTH, state the nuance.** These are the absolutes most often stated incorrectly about HMS in an Iceberg-on-MinIO stack. Each TRUTH below has been verified against the [Iceberg HMS catalog docs](https://iceberg.apache.org/docs/latest/hive/) and the [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html).

| MYTH (commonly said wrong) | TRUTH (correct framing) |
|---|---|
| "HMS holds the partition list for Iceberg tables — so I need to run `MSCK REPAIR TABLE` after writes to refresh partitions." | **NO — `MSCK REPAIR TABLE` is a Hive-table operation and does NOTHING USEFUL for Iceberg tables.** Iceberg tracks files and partitions in its own manifests in MinIO; HMS for an Iceberg table holds only the current `metadata.json` pointer. The Iceberg writer (Spark, Trino INSERT, etc.) atomically commits new manifests + advances the HMS pointer in one transaction. No `MSCK REPAIR` needed; if you see it in a runbook for an Iceberg table, that runbook was written for the legacy Hive code path. |
| "HMS is a single point of failure — if HMS goes down, all queries fail immediately." | **PARTIALLY TRUE — but only at query plan time.** Trino calls HMS during query planning to resolve the table's current `metadata.json` pointer. Once planning is done, HMS is NOT in the execution data path — already-planned queries run to completion even if HMS dies mid-execution. NEW queries fail until HMS is back. Mitigations: run HMS as HA pair behind a k8s Service, cache metadata at the Trino coordinator via `hive.metastore-cache-ttl`, or migrate to a REST catalog (Nessie / Polaris / Tabular) that's typically scaled-out HA by design. |
| "I can edit the HMS `metadata_location` column directly to roll back an Iceberg table." | **NO — DO NOT do this.** Iceberg's commit protocol uses atomic compare-and-swap against the HMS `metadata_location`; a manual UPDATE bypasses Iceberg's own transactional logic and can leave the table in an inconsistent state if a concurrent writer is committing. **Use `CALL iceberg.system.rollback_to_snapshot('schema', 'table', <snapshot_id>)`** instead — it does the right metadata.json rewrite + HMS pointer swap atomically. For the Trino 467 syntax see resource 17's version-feature matrix. |
| "Hive views migrate automatically when I migrate a Hive table to Iceberg via `snapshot` / `migrate`." | **NO — only the table itself migrates.** Hive views that reference the table are NOT updated. Iceberg `migrate` and `snapshot` rewrite the TABLE entry in HMS to point at Iceberg metadata; Hive views remain unchanged in HMS and continue to reference the old Hive table definition (which no longer has data files). You must recreate the views as Trino/Iceberg views explicitly after migration. There is no Hive-view-to-Iceberg-view auto-migration in Spark or Trino. |
| "Trino's Iceberg connector and the Hive connector see the same tables in HMS — I can query an Iceberg table via the `hive` catalog." | **NO — the connectors are mutually exclusive per table.** Trino's `hive` connector explicitly REJECTS Iceberg tables ("Cannot query Iceberg table") and the `iceberg` connector explicitly REJECTS Hive tables. The connector checks the table's `table_type` HMS property (`ICEBERG` vs the default Hive type) and dispatches accordingly. Configure two catalogs (one `hive`-typed, one `iceberg`-typed) pointing at the same HMS; users pick the right catalog name in their query. |
| "Migrating from HMS to a REST catalog (Nessie / Polaris) requires a long write-freeze on every table." | **It requires a write-freeze PER TABLE for the duration of the snapshot-to-REST registration, but NOT a global cluster-wide freeze for the whole window.** The migration pattern is: pause writes on table X, take its current `metadata.json` path from HMS, register it in the REST catalog via `register_table`, swap the writers/readers to the REST catalog, resume writes. Other tables on HMS keep working concurrently. The PER-TABLE freeze is usually seconds to a few minutes — long enough for any in-flight Spark write to finish committing. Plan one table at a time; do not attempt a single big-bang cutover. |
| "HMS auto-cleans up unreferenced Iceberg metadata files when I `DROP TABLE`." | **NO — `DROP TABLE` semantics depend on the engine and HMS settings.** By default in HMS, dropping a table marks it deleted in HMS but the underlying data + metadata files in MinIO REMAIN unless the table was marked `EXTERNAL=false` AND the storage handler honors deletion. For Iceberg, Trino's `DROP TABLE` does remove the data and metadata files by default (since Trino 384+). Spark Iceberg `DROP TABLE PURGE` removes them; `DROP TABLE` without PURGE may not, depending on the catalog config. **Always verify with a manual `mc ls` against MinIO after a DROP** before assuming storage was reclaimed. |
| "HMS schema migrations happen automatically when I upgrade Iceberg or Trino." | **NO — HMS has its own backing-store schema** (typically Postgres or MySQL), upgraded by running the HMS `schematool -upgradeSchema` command separately. Upgrading Iceberg's library version or Trino's connector version does NOT touch the HMS Postgres schema. Plan HMS upgrades as their own change with their own rollback window. |

> **Why these specific myths matter.** Each is a load-bearing claim about HMS-Iceberg interaction. Stated as an absolute, they cause engineers to either build expensive workarounds for non-problems (writing `MSCK REPAIR` jobs for Iceberg tables; freezing the whole catalog for an HMS-to-REST migration) OR to confidently break things (editing HMS `metadata_location` manually and corrupting commit semantics; assuming `DROP TABLE` cleaned up storage when it didn't). **The correct discipline:** when about to say "HMS does/doesn't X for Iceberg", check (a) the Iceberg HMS catalog docs, (b) the Trino Iceberg connector docs, (c) whether the claim is for an Iceberg table or a legacy Hive table — most "HMS does X" claims are about Hive tables and don't apply to Iceberg.

---

## Migrating existing Hive Parquet tables to Iceberg (in-place, no data rewrite)

> **Common misconception**: "Migrating from Hive to Iceberg means rewriting all your data files." **This is wrong.** Iceberg provides a metadata-only migration path. A 100 GB Hive Parquet table converts to Iceberg in minutes, not hours — because no data files are touched.

### The two migration commands

Both run from **Spark SQL** (not Trino — Trino does not implement the migration stored procedures).

#### Option 1: `CALL catalog.system.migrate()` — in-place, permanent

Replaces the Hive table definition with Iceberg metadata **without rewriting any data files**. After the call, the table is an Iceberg table. The original Hive table definition is gone.

```sql
-- Spark SQL — convert a Hive Parquet table to Iceberg in-place
CALL iceberg.system.migrate('analytics.events');
```

What actually happens:
1. Spark reads the existing Parquet file list from HMS (or the file system).
2. It builds Iceberg snapshot + manifest metadata on top of those existing files.
3. HMS's table definition is updated to point at the new Iceberg `metadata.json`.
4. **No Parquet files are moved, renamed, or rewritten.** The data bytes on MinIO are untouched.

Completion time is proportional to the number of files, not the data size. A 100 GB table with 500 Parquet files typically takes 1–5 minutes.

#### Option 2: `CALL catalog.system.snapshot()` — shadow copy, non-destructive

Creates a **new Iceberg table** that references the same Parquet files as the original Hive table. The original Hive table continues to exist unchanged. Use this to validate Iceberg behavior before committing to a full migration.

```sql
-- Spark SQL — create an Iceberg shadow table without touching the Hive table
CALL iceberg.system.snapshot('analytics.events', 'analytics.events_iceberg');
```

Both `analytics.events` (Hive) and `analytics.events_iceberg` (Iceberg) will point at the same underlying Parquet files. You can query the Iceberg copy through Trino, verify the results, and then run `migrate()` on the original when you're confident.

**Important**: do not delete or modify the original Hive table's files after creating a snapshot — both tables are reading the same physical files.

### Post-migration steps

After `migrate()` (or after you're done validating `snapshot()` and have migrated), run two follow-up procedures:

**1. Rebuild manifests for proper Iceberg structure:**

```sql
-- Spark SQL — rebuild manifests after migration
CALL iceberg.system.rewrite_manifests('analytics.events');
```

The freshly-migrated table has one manifest entry per pre-existing Parquet file — potentially thousands of small manifest entries if the Hive table had many partitions. `rewrite_manifests` consolidates these into fewer, well-structured Iceberg manifests. This significantly speeds up query planning in Trino for large migrated tables.

**2. (Optional) Upgrade to format version 2 if you need row-level deletes:**

```sql
-- Spark SQL — upgrade from Iceberg v1 to v2 format
ALTER TABLE iceberg.analytics.events
SET TBLPROPERTIES ('format-version' = '2');
```

**Hive-MIGRATED tables (via Spark's `migrate()`) default to Iceberg format version 1**, which does not support delete files (used by `MERGE INTO` and row-level `DELETE` statements). If you plan to use those operations on a migrated table, upgrade it to v2 with the `ALTER TABLE ... SET TBLPROPERTIES ('format-version'='2')` above. Read-only tables and append-only tables do not need v2.

> **IMPORTANT — this v1 default applies ONLY to tables produced by Spark's `migrate()` procedure. It does NOT apply to brand-new tables.** A **NEW** Iceberg table created with `CREATE TABLE` on **Trino 467** — or by a dbt-trino `materialized='table'` / `'incremental'` model — **defaults to `format_version = 2`** (the Trino Iceberg `format_version` table property has defaulted to `2` since **Trino 419**, well before 467; verified [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html)). So **`MERGE INTO` / row-level `DELETE` / `UPDATE` work out of the box on new Trino-created Iceberg tables — you do NOT need to set `format_version=2` first.** Only LEGACY Hive-migrated v1 tables need the explicit v1→v2 upgrade. Keyword anchors: do I need format_version 2 before MERGE, Trino 467 default format_version new table, new CREATE TABLE v2 default, migrated v1 vs new-table v2. **DO-NOT-WRITE:** "Default Iceberg tables are format v1, set format_version=2 before MERGE" — WRONG for new Trino-created tables (they are already v2); it is true ONLY for Spark-`migrate()`-produced tables. See also [resource 17 §formats](17-iceberg-table-maintenance.md) and [resource 25](25-iceberg-format-internals.md) for the new-table v2 default.

### Summary of limitations

| Concern | Detail |
|---|---|
| `migrate()` is permanent | The original Hive table definition is replaced. Run `snapshot()` first if you want a safety net. |
| `snapshot()` shares files | Do not delete the Hive table's data directory after creating a snapshot — the Iceberg copy reads those files too. |
| Runs from Spark, not Trino | Trino does not implement `CALL system.migrate()`. Use a Spark session or a Spark-based notebook. |
| Migrated table starts at format v1 | No delete files until you `ALTER TABLE ... SET TBLPROPERTIES ('format-version' = '2')`. |
| Run `rewrite_manifests` after migration | Skipping this leaves the table with a poorly-structured manifest that slows Trino query planning. |

### The bottom line

If you have existing Hive Parquet tables and want to move them to Iceberg: run `CALL iceberg.system.migrate('your_schema.your_table')` from Spark. It completes in minutes regardless of data size. No ETL pipeline needed, no data copy, no downtime window proportional to table size.

---

## Per-query access pattern: HMS is on the critical path for every new query

When Trino runs a query against an Iceberg table, the first thing the Iceberg connector does is **ask HMS for the current `metadata.json` pointer for each table in the query**. This happens **every single time** a new query starts.

The sequence:

```
1. User submits:  SELECT COUNT(*) FROM iceberg.analytics.user_events WHERE ...
2. Trino coordinator parses + plans the query.
3. For each table in the FROM clause:
     -> Iceberg connector sends a Thrift RPC to HMS:
        "Give me the current metadata_location for analytics.user_events"
     -> HMS does a one-row Postgres lookup, returns the s3a:// pointer.
4. Trino then reads metadata.json from MinIO (NOT from HMS) to get the
   current snapshot, schema, partition spec, and manifest list location.
5. Trino reads the manifest list + manifests from MinIO to plan which
   data files to open. (Still no HMS calls.)
6. Workers read data files from MinIO. (Still no HMS calls.)
```

**Key facts about this pattern:**

- **Every new query hits HMS.** There is no per-table caching of HMS results in Trino's Iceberg connector — the upstream issue [trinodb/trino#13115](https://github.com/trinodb/trino/issues/13115) tracks this explicitly. The reasoning is correctness: if Trino cached the metadata pointer, it would miss writes from concurrent Spark jobs and serve stale snapshots. Iceberg's whole concurrency story rests on every reader picking up the current pointer at query plan time.
- **The call is cheap.** It's a single Thrift RPC returning a single string (the metadata path). Wire time is typically <10 ms. This is the opposite of the legacy Hive connector, which fetched per-partition rows from HMS during planning and could spend many seconds on partition enumeration for large tables.
- **The call is on the critical path.** The query cannot start planning files until the metadata pointer resolves. If HMS is slow (10s of seconds), queries appear to "hang at startup." If HMS is unreachable, new queries fail immediately.

**This is different from the legacy Hive connector.** Trino's Hive connector (used for non-Iceberg Hive tables) does cache HMS partition listings via its `hive.metastore-cache-ttl` setting, because those listings are expensive to refetch. The Iceberg connector intentionally does NOT cache — the catalog call is cheap and caching would break snapshot semantics. **Do not assume Hive-connector caching applies to your Iceberg tables; it doesn't.**

---

## Failure modes: what happens when HMS is down

Different things break depending on whether a query is starting fresh or already in flight.

### New queries: fail fast

Any new query that touches an Iceberg table fails immediately with an error like:

```
io.trino.spi.TrinoException: Failed connecting to Hive metastore: thrift://hms:9083
  Caused by: org.apache.thrift.transport.TTransportException:
    java.net.ConnectException: Connection refused (Connection refused)
```

The coordinator gives up before doing any planning. The user sees the error in their client. No data is touched in MinIO. **HMS-down = no new Iceberg queries can start.**

This includes:
- New ad-hoc SELECTs from the Trino UI or CLI.
- New dashboard refreshes.
- New dbt model runs.
- New Spark ingestion jobs (Spark also resolves the table through HMS before writing).

### In-flight queries: usually survive

Once a query has progressed past step 3 in the sequence above — i.e., Trino has already resolved the metadata pointer and is reading manifests + data files from MinIO — **HMS is no longer needed for the rest of that query's execution**. The scan loop is driven entirely by Iceberg metadata files and Parquet data files in MinIO. Workers don't call HMS while scanning.

So a brief HMS outage that starts after a query is already executing typically lets that query finish normally. This is a quietly important reliability property: a 30-second HMS hiccup during execution is usually invisible to in-flight queries, even though it blocks all new queries from starting.

**Edge cases where in-flight queries can still fail during an HMS outage:**

- Queries that perform `INSERT INTO ... SELECT ...` (like the ad-hoc result-export pattern documented in `prod_info.md`) need to commit a new snapshot at the end, which requires HMS to update the metadata pointer. The SELECT part finishes, but the INSERT commit fails.
- CTAS (`CREATE TABLE AS SELECT`) needs HMS at commit time to register the new table.
- Multi-statement transactions (rare in Trino) need HMS for the commit.

For read-only `SELECT` queries already past planning, HMS being down is usually a non-event.

### Practical implication: HMS is a single point of failure for query *startup*

The net effect for the cluster:

- **HMS down**: zero new Iceberg queries can start. Most in-flight `SELECT` queries finish. All ingestion (Spark writes) blocks. The system "freezes" from the user's perspective even though existing queries are still working.
- **HMS down for hours**: dashboard refresh cycles stop returning new data. Users see "query failed" errors. Spark ingestion jobs back up. Recovery time = HMS restart time + queued ingestion catch-up time.

This is the SPOF risk you need to mitigate with HA, or eliminate by switching catalog type.

---

## HA recipe for HMS on Kubernetes

The standard HA pattern for HMS in a k8s cluster has three parts:

### 1. Stateless HMS pods with `replicas: N`

HMS pods are stateless — they hold no in-process state. Everything HMS knows is in its backing relational database. This means you can run multiple HMS pods behind a service and they will all answer the same questions identically.

```yaml
# Excerpt from your HMS Deployment manifest
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hive-metastore
spec:
  replicas: 3                  # at least 2; 3 gives N+1 redundancy during rolling restart
  template:
    spec:
      containers:
        - name: hms
          image: apache/hive:3.1.3
          ports:
            - containerPort: 9083    # Thrift port
          env:
            - name: SERVICE_NAME
              value: metastore
            - name: DB_DRIVER
              value: postgres
            # ...connection details to your HA Postgres backend...
---
apiVersion: v1
kind: Service
metadata:
  name: hive-metastore
spec:
  selector:
    app: hive-metastore
  ports:
    - port: 9083
      targetPort: 9083
  type: ClusterIP             # k8s service already load-balances across the 3 pods
```

The k8s `Service` object already provides round-robin load balancing across the pod replicas. **You usually don't need an external load balancer (HAProxy, NGINX) in front of HMS** — the k8s Service is sufficient for Thrift connections.

### 2. HA Postgres (or MySQL) backing HMS — the real SPOF

**This is the most commonly missed part.** Three stateless HMS pods backed by a **single, non-HA Postgres** are no more available than one HMS pod — when that Postgres dies, all three HMS pods fail to serve queries. **The RDBMS behind HMS is the actual SPOF.**

The backing database must be made HA separately. On-prem k8s options:

- **Cloud-native Postgres (CNPG) operator**: deploys a primary + N synchronous replicas with automatic failover. Trades a small write-latency cost for survival of a primary loss.
- **Patroni-based Postgres clusters**: similar pattern, longer-established.
- **External managed Postgres** (if your data center has one): point HMS at it; outsource the HA problem.
- **For development only**: a single-pod Postgres with a PVC. Acceptable for non-production HMS — never for prod.

The HMS pods don't care which HA strategy you pick — they just see a JDBC URL pointing at whatever the HA primary is at the moment. Make sure the JDBC URL uses a service name that resolves to the current primary (not a fixed pod IP).

### 3. Trino points at all HMS pods via comma-separated URIs

Configure Trino's Iceberg catalog to know about every HMS pod, so a single pod failure doesn't kill connectivity:

```properties
# /etc/trino/catalog/iceberg.properties
connector.name=iceberg
iceberg.catalog.type=hive_metastore
hive.metastore.uri=thrift://hms-0.hive-metastore:9083,thrift://hms-1.hive-metastore:9083,thrift://hms-2.hive-metastore:9083

# Alternatively, if your HMS pods are behind a k8s Service (the recommended pattern),
# point at the service DNS name — k8s Service handles load balancing across all healthy pods:
# hive.metastore.uri=thrift://hive-metastore:9083
```

**Two ways to do this, both valid:**
- **Per-pod URIs (comma-separated)**: explicit; Trino picks one at random on each connection attempt and rotates on failure. Survives the k8s control plane being slow to mark a failed pod unhealthy.
- **Single k8s Service URI**: simpler; relies on k8s Service to load-balance and remove unhealthy pods from rotation. Fewer URIs to maintain, but adds a small latency for k8s endpoint updates after a pod failure.

For production reliability the per-pod comma-separated form is slightly safer (faster failover during the k8s endpoint-update lag) but the Service form is simpler and usually fine. Either works.

### What HMS HA does NOT protect against

Even a fully HA HMS setup has limits:

- **Connectivity between Trino and HMS**: if the k8s network between the Trino pods and the HMS pods breaks (network policy misconfiguration, CNI failure), HMS being "up" doesn't help. Monitor end-to-end.
- **Postgres backend correctness**: HMS will happily serve corrupted pointer data if the backing Postgres has been restored from an old backup that's out of sync with what's in MinIO. After a Postgres recovery, audit the `metadata_location` pointers against actual MinIO contents before reopening to query traffic.
- **HMS schema migrations**: a botched upgrade of the HMS image to a version with incompatible schema changes brings down all HMS pods simultaneously. Test HMS upgrades in a non-prod environment first; pin the HMS image version in your Helm chart and update deliberately.

---

## The alternative: skip HMS entirely with an Iceberg REST catalog

If HMS being on the critical path for every new query is a structural problem you don't want to keep solving with HA — or if you'd rather not run yet another Java-based service on k8s — you can replace HMS with an **Iceberg REST catalog**. This is the long-term architectural answer to the HMS SPOF problem.

### What an Iceberg REST catalog is

The Iceberg project defines a [REST catalog spec](https://iceberg.apache.org/concepts/catalog/) — a simple HTTP API for the same operations HMS provides (list namespaces, list tables, resolve metadata pointer, commit new snapshots). Any service that implements this spec can be a catalog for Iceberg tables. Trino and Spark both support `iceberg.catalog.type=rest` out of the box.

The benefits for your stack:

- **Single, well-defined HTTP API** instead of HMS's Thrift + relational schema + Postgres backend. Easier to run, monitor, scale, and replace.
- **Native HA primitives** — REST catalogs are typically stateless and put their state in a generic database; standard HTTP load balancers, retries, and health checks apply.
- **Designed for Iceberg**, not retrofitted onto a Hive-era system. No legacy partition table, no Hive-style assumptions.
- **Standardized commit protocol** — atomic snapshot commits with optimistic concurrency are part of the REST spec, rather than relying on HMS's table-level lock semantics.

### Open-source REST catalog implementations

All of these can run on-prem in k8s and work with MinIO:

> **XR REDIRECT — READING an Iceberg branch or tag from Trino on HMS-backed Iceberg? You do NOT need Nessie.** This is the most common load-bearing fab on this topic (iter463 Q1, 2026-06-05). Iceberg **branches and tags are TABLE-LEVEL Iceberg metadata** — they live inside the table's `metadata.json` file in MinIO and are listed in the `"<table>$refs"` metadata table. They are **catalog-agnostic**: fully supported on **Hive Metastore-backed Iceberg**, on REST-catalog-backed Iceberg, on JDBC-catalog-backed Iceberg, etc. The Apache Iceberg docs list "Branching and Tagging" under the **Tables** section at [iceberg.apache.org/docs/latest/branching/](https://iceberg.apache.org/docs/latest/branching/), NOT under any catalog-specific section.
>
> **What Nessie ADDS on top is a DIFFERENT, SEPARATE feature — CATALOG-LEVEL multi-table branch transactions** (atomic branching across MANY tables at once, "PR-style" data workflows that touch multiple tables in one ref). That is the *unique* Nessie value-add over HMS. **Single-table branches/tags are NOT a Nessie-only feature.**
>
> **How to READ a branch or tag from Trino 467 on HMS-backed Iceberg** — `SELECT * FROM iceberg.<schema>.<table> FOR VERSION AS OF '<branch_or_tag_name>';` (string literal name; the same `FOR VERSION AS OF` clause also accepts an unquoted BIGINT snapshot_id). The full canonical block — with the BIGINT-vs-string disambiguation table, the cross-dialect-spillover DO-NOT-WRITE matrix, and engine-by-engine muscle-memory map — is in [§ LEADING CANONICAL — Iceberg time travel on Trino 467 in resources/17-iceberg-table-maintenance.md](17-iceberg-table-maintenance.md#leading-canonical--iceberg-time-travel-on-trino-467-two-separate-clauses-not-interchangeable).
>
> **How branches and tags are CREATED on HMS-backed Iceberg** — from **Spark**, via `ALTER TABLE ... CREATE BRANCH \`<name>\`` and `ALTER TABLE ... CREATE TAG \`<name>\` AS OF VERSION <snapshot_id>` (Spark Iceberg DDL). **Trino 467 cannot create or drop branches/tags from any catalog type** (HMS, REST, or Nessie); ref-write DDL is Spark-only on Trino 467 per [trinodb/trino #16570](https://github.com/trinodb/trino/issues/16570) (request closed as NOT PLANNED). Trino 467 **CAN read** a branch / tag via the `FOR VERSION AS OF '<name>'` form above per [trinodb/trino #16569](https://github.com/trinodb/trino/issues/16569). Same engine-support matrix on HMS, REST catalog, and Nessie — the read/write split is a **Trino vs Spark** matter, NOT a catalog matter.
>
> Verified at [iceberg.apache.org/docs/latest/branching/](https://iceberg.apache.org/docs/latest/branching/) (Branching and Tagging under the Tables section, catalog-agnostic), [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) (Time travel — `FOR VERSION AS OF '<branch-name>'` documented as supported on the Iceberg connector regardless of catalog type).

| Implementation | Notes |
|---|---|
| **Apache Polaris** | Donated to ASF by Snowflake in 2024; first-class Iceberg REST catalog. Active community. Backed by a generic relational DB (Postgres works). |
| **Lakekeeper** | Rust-based REST catalog. Lightweight; lower memory footprint than JVM-based options. Active development. |
| **Apache Gravitino** | Broader metadata platform that includes a REST catalog for Iceberg plus catalogs for other systems. Heavier; choose if you want a unified metadata service across multiple data systems. |
| **Project Nessie** | **CATALOG-LEVEL multi-table branch transactions** (atomic multi-table branching, "PR-style" workflows that touch many tables in one ref). Choose if you want catalog-level branching across many tables at once. **Note:** single-table branches and tags do NOT require Nessie — they are catalog-agnostic table-level Iceberg metadata available on HMS too (see XR REDIRECT above). |
| **Tabular's catalog (now Databricks Unity Catalog OSS)** | Mature REST catalog, OSS edition available. Heavier dependency footprint. |

For an on-prem k8s deployment that just wants to escape the HMS SPOF, **Polaris** or **Lakekeeper** are the simplest first steps — both are dedicated Iceberg REST catalogs without extra scope.

### Trino config for REST catalog

Switching is a Trino catalog config change. The migration itself — moving table metadata pointers from HMS to the REST catalog — is more involved (you'd typically write a one-time script that enumerates HMS tables and re-registers them in the REST catalog), but the Trino-side config is just:

```properties
# /etc/trino/catalog/iceberg.properties — REST catalog instead of HMS
connector.name=iceberg
iceberg.catalog.type=rest
iceberg.rest-catalog.uri=http://polaris-catalog.iceberg-system:8181/api/catalog
iceberg.rest-catalog.warehouse=s3://lakehouse/
# Auth config depends on the REST catalog implementation (OAuth2, JWT, mTLS, etc.)
iceberg.rest-catalog.security=OAUTH2
iceberg.rest-catalog.oauth2.token=<token-or-token-endpoint-config>

# MinIO / S3 config stays the same
fs.native-s3.enabled=true
s3.endpoint=http://minio:9000
s3.path-style-access=true
s3.region=us-east-1
s3.aws-access-key=<minio-access>
s3.aws-secret-key=<minio-secret>
```

Spark gets a similar `iceberg.catalog.<name>.type=rest` config change. Once both sides point at the REST catalog and tables are re-registered, HMS can be retired.

### When to migrate vs stay on HMS

| Situation | Recommendation |
|---|---|
| Current HMS works, HA is in place, no major pain | Stay on HMS. The migration cost isn't worth it for a system that's working. |
| HMS outages cause repeated incidents; HA is hard to maintain (Postgres failover misfires, HMS pods OOM, etc.) | Plan a REST catalog migration. The structural reduction in operational surface area is worth the one-time cost. |
| New project / greenfield Iceberg deployment | Start with REST catalog (Polaris or Lakekeeper). Save yourself the future migration. |
| Multi-engine federation (Spark + Trino + Flink + Dremio + custom) | REST catalog scales better — one HTTP API instead of N engines each maintaining their own HMS Thrift client. |
| Team has deep HMS expertise but no REST-catalog operational experience | Stay on HMS until the team is comfortable with the alternative. Operational familiarity matters. |

The REST catalog isn't strictly "better" than a properly-run HA HMS for every workload — it's a different operational shape. For most on-prem stacks that already have HMS working with HA, **the right move is to keep HMS healthy and only migrate when the pain justifies the migration cost**. Greenfield deployments should start with REST.

---

## Other catalog alternatives (briefly)

For completeness, two more catalog types Iceberg supports:

- **JDBC catalog (`iceberg.catalog.type=jdbc`)**: stores Iceberg table metadata pointers directly in a relational DB you provide (Postgres, MySQL), without HMS in between. Simpler than HMS (no Thrift service to run) but lacks some HMS features (e.g., the Hive privilege model). A reasonable choice for small deployments that don't want to operate either HMS or a REST catalog service.
- **AWS Glue (`iceberg.catalog.type=glue`)**: managed catalog on AWS. **Not applicable to this on-prem stack** — listed only for awareness if you ever see it in documentation.
- **Hadoop catalog (`iceberg.catalog.type=hadoop`)**: file-system-only catalog where the "directory listing" itself is the catalog. **Avoid in production** — it relies on atomic file rename, which S3/MinIO does NOT provide. Safe only for read-only browsing of pre-built Iceberg tables, not for any system that writes concurrently.

For on-prem with MinIO, the realistic choices are: **HMS** (status quo), **REST catalog** (Polaris/Lakekeeper/Nessie, recommended long-term), or **JDBC catalog** (simpler middle ground).

---

## HMS -> Nessie no-downtime migration — the mechanics

> **The migration is metadata-only.** Iceberg tables in HMS and in Nessie point at the **same `metadata.json` files in MinIO** — no data files move, no Parquet rewrites, no compaction. The migration changes WHICH catalog holds the current-`metadata.json` pointer; the data is shared. This is what makes a true no-downtime migration possible.

### The atomic unit of migration: one table's catalog registration

For each Iceberg table, the migration does ONE of two things:

1. **`registerTable`** (Java API: `Catalog.registerTable(TableIdentifier, metadataLocation)`) — Nessie reads the current `metadata.json` location from HMS, then writes a new pointer record in Nessie to the **same** `metadata.json`. Both catalogs now know about the table; both can read it. Writes from either catalog produce new `metadata.json` files in MinIO, but only the WRITING catalog's pointer advances. This is the **dual-write window** below.
2. **Cutover** — flip writers from HMS-pointed-Trino/Spark to Nessie-pointed-Trino/Spark. HMS still has the old `metadata.json` pointer (it remains queryable for a frozen view); Nessie now holds the live pointer that writers advance.

### The [iceberg-catalog-migrator](https://github.com/projectnessie/iceberg-catalog-migrator) tool

Project Nessie ships an official CLI that bulk-registers tables between any two Iceberg catalog implementations. Typical invocation:

```bash
java -jar iceberg-catalog-migrator-cli.jar register \
  --source-catalog-type HIVE \
  --source-catalog-properties uri=thrift://hms.iceberg.svc.cluster.local:9083 \
  --source-catalog-hadoop-conf fs.s3a.endpoint=http://minio.minio.svc.cluster.local:9000 \
  --target-catalog-type NESSIE \
  --target-catalog-properties uri=http://nessie.nessie.svc.cluster.local:19120/api/v1,ref=main \
  --identifiers-from-file tables_to_migrate.txt
```

The tool walks the source catalog, reads each table's current `metadata.json` location, and calls `registerTable` on the target catalog with the SAME location. **No data movement, no `metadata.json` rewrites.** A 10,000-table catalog migrates in minutes (limited by HMS read throughput, not by MinIO data motion).

### The dual-write window — the no-downtime mechanism

The migration follows a four-phase pattern that keeps writes available the entire time:

| Phase | HMS state | Nessie state | Trino writers point at | Spark writers point at | Readers point at |
|---|---|---|---|---|---|
| **0. Baseline** | All tables, live pointer | (Nessie not yet deployed) | HMS | HMS | HMS |
| **1. Nessie deployed, tables registered** | All tables, live pointer | All tables registered, **pointer matches HMS** | HMS | HMS | HMS (Nessie shadow-readable for testing) |
| **2. Readers cut over** | All tables, live pointer | All tables, **pointer matches HMS** | HMS (still writing) | HMS (still writing) | **Nessie** (catches all writes via re-register) |
| **3. Writers cut over** | All tables, **pointer frozen** at cutover moment | All tables, **live pointer** | **Nessie** | **Nessie** | **Nessie** |
| **4. HMS decommissioned** | (deleted) | All tables, live pointer | Nessie | Nessie | Nessie |

**The critical phase is Phase 2 -> Phase 3.** Between registering tables in Nessie (Phase 1) and cutting writers over (Phase 3), there is a window where readers use Nessie but writers still use HMS. **Any write during this window advances HMS's pointer but NOT Nessie's** — Nessie now has a stale pointer. The two reconciliation patterns:

- **Re-register periodically.** Run the migrator tool's `register --overwrite` mode every N minutes during Phase 2 to copy HMS's latest pointer into Nessie. Each re-register is metadata-only and atomic. Readers using Nessie see slightly-stale snapshots; if your reader workload tolerates 5-minute staleness, this is fine.
- **Freeze writes briefly at cutover.** Run a final re-register, then within seconds flip writers from HMS to Nessie. This is the "near-zero-downtime" form — typically ~30 seconds where writes pause; readers are unaffected.

### What can go wrong (and how to avoid it)

- **Stale Nessie pointer after Phase 2.** Symptom: a reader using Nessie misses recent writes that landed via HMS. **Fix**: schedule periodic `register --overwrite` during the dual-write window, OR cut writers over quickly (within minutes of registering tables).
- **Concurrent writes from both catalogs.** Symptom: Spark writing via HMS and another Spark job writing via Nessie produce two divergent `metadata.json` chains. **Fix**: **never allow concurrent writes from both catalogs to the same table.** Cutover writers atomically — flip the Spark / Trino config to point at Nessie in one deployment, not gradually.
- **Old `metadata.json` chain orphaned in HMS.** After cutover, HMS's pointer still references the pre-cutover `metadata.json`. **This is fine — the data is shared in MinIO.** The HMS pointer becomes a frozen view of the table at cutover time, useful for audit / rollback. Decommission HMS once you're confident the migration succeeded.
- **`fs.s3a.endpoint` / MinIO credentials missing from the migrator's Hadoop config.** Symptom: the migrator tool fails to read `metadata.json` from MinIO. **Fix**: pass the S3A endpoint, access key, and secret to the migrator via `--source-catalog-hadoop-conf` so it can read the metadata files; the same config the production Spark and Trino use applies here.
- **View / schema definitions.** The catalog migrator handles Iceberg tables only — Hive **views** (non-Iceberg `_VIEW` rows in HMS) do NOT migrate. Plan a separate inventory + manual recreate step for any Hive views that downstream queries depend on.

### Why HMS -> Nessie is structurally cheaper than data migration

A re-platform that required moving data files (e.g., switching from Parquet to a different format) would mean: read every file, rewrite it, update catalog pointers, validate, decommission old files. That's hours-to-days per terabyte, plus 2x storage during the transition. **HMS -> Nessie is not that** — it's purely a metadata-layer swap. **No data motion. No storage doubling. No compaction. No file format change.** The cost is bounded by the count of tables, not the volume of data. A 100 TB Iceberg warehouse migrates in the same wall-clock time as a 100 GB one (both are dominated by catalog round-trips, not data I/O).

### When to do it vs not

| Situation | Recommendation |
|---|---|
| HMS HA is working, no Nessie-specific feature need | Stay on HMS. Migration cost > benefit. |
| Need catalog-level **multi-table** branching (PR-style workflows that atomically branch many tables at once, "dev" branch spanning the entire warehouse) | **Migrate to Nessie** — multi-table catalog-level branch transactions are the unique feature Nessie offers over HMS. **NOT to be confused with single-table branches/tags**, which are TABLE-LEVEL Iceberg metadata available on HMS too — see the XR REDIRECT in [§ Open-source REST catalog implementations](#open-source-rest-catalog-implementations) above. |
| Need multi-engine catalog (Trino + Spark + Flink + Dremio all hitting one HTTP API) | Migrate to a REST catalog — Nessie, Polaris, or Lakekeeper. Choice between them is operational preference. |
| Frequent HMS outages from Postgres failover, HMS OOM, Thrift socket exhaustion | Migrate to a REST catalog. Eliminates the Thrift + Postgres operational pair. |

For this on-prem stack with MinIO, the migration playbook above works the same for **Nessie, Polaris, or Lakekeeper** — the catalog choice is a deployment decision, not a migration mechanism difference. The `iceberg-catalog-migrator` supports all three target types.

---

## Quick reference

| Question | Answer |
|---|---|
| What does HMS store for an Iceberg table? | One row per table; the only Iceberg-specific column is the path to the current `metadata.json` in MinIO. |
| What does HMS NOT store for Iceberg? | Partition lists, file lists, column stats, snapshots, schema history — all of these live in Iceberg metadata files in MinIO. |
| Does Trino contact HMS for every query? | **Yes** — once per Iceberg table in the query, at planning time. No per-table cache in the Iceberg connector (trinodb/trino#13115). |
| Is the HMS call slow? | No — it's a single Thrift RPC returning a string. Typically <10 ms. But it IS on the critical path. |
| What breaks when HMS goes down? | New queries fail immediately. In-flight `SELECT`s usually finish (their planning is done). New INSERTs / CTAS / Spark writes block (need HMS at commit time). |
| Is HMS itself stateful? | No — HMS pods are stateless. All state lives in the backing relational DB (Postgres/MySQL). |
| What's the actual SPOF in an "HMS HA" setup? | The backing **Postgres/MySQL**. Stateless HMS pods + non-HA Postgres = the Postgres is the SPOF. HA the database too. |
| How does Trino discover multiple HMS pods? | Comma-separated `hive.metastore.uri=thrift://hms-1:9083,thrift://hms-2:9083` in `iceberg.properties`, OR a single k8s Service URI that load-balances internally. |
| How do I eliminate the HMS SPOF entirely? | Switch to an Iceberg **REST catalog** (`iceberg.catalog.type=rest`). Implementations: Polaris, Lakekeeper, Gravitino, Nessie. Trino and Spark both support it natively. |

---

## Key terms

- **Catalog (in Iceberg)**: the service that knows the current `metadata.json` location for each Iceberg table. HMS, REST catalog, JDBC catalog, and Hadoop catalog are all "catalog implementations."
- **Metadata pointer / `metadata.json`**: the root of an Iceberg table's metadata tree in object storage. Every snapshot of the table has its own `metadata.json`; the catalog tracks which one is "current."
- **Snapshot**: an atomic version of an Iceberg table. Writes produce a new snapshot; the catalog atomically updates the pointer to make that snapshot visible to readers.
- **Manifest list / manifest**: Iceberg's per-snapshot index of data files. Lives in MinIO, not HMS. Trino reads these to plan which Parquet files to open.
- **Thrift**: the binary RPC protocol HMS uses (port 9083). Predates REST; reason HMS feels "old."
- **REST catalog**: an Iceberg-native catalog with an HTTP API instead of Thrift. The modern alternative to HMS.
- **SPOF**: single point of failure. HMS is one; its backing DB is the real one if HMS is run with replicas but the DB isn't.
