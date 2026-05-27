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

| Implementation | Notes |
|---|---|
| **Apache Polaris** | Donated to ASF by Snowflake in 2024; first-class Iceberg REST catalog. Active community. Backed by a generic relational DB (Postgres works). |
| **Lakekeeper** | Rust-based REST catalog. Lightweight; lower memory footprint than JVM-based options. Active development. |
| **Apache Gravitino** | Broader metadata platform that includes a REST catalog for Iceberg plus catalogs for other systems. Heavier; choose if you want a unified metadata service across multiple data systems. |
| **Project Nessie** | Git-style branching/tagging for Iceberg tables on top of REST catalog semantics. Choose if you want catalog-level branching (multi-environment isolation, "PR" workflows on data). |
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
