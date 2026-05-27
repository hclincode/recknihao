# Iter142 Q1 — Answer

**Question**: "Our whole analytics setup went down this morning and someone said the 'Hive Metastore' was unreachable. I had no idea we even had something called that, and now I'm worried — what exactly is this thing, what breaks when it goes down, and how do we make sure we can recover quickly if it happens again? Is this something we need to back up separately, or is our data actually safe even if it crashes?"

---

## What the Hive Metastore Is and What It Stores

The **Hive Metastore** is a directory service — think of it as a filing cabinet that tracks what tables exist in your lakehouse and where each table's files live in MinIO. It does not store the actual data (your events, users, transactions). It stores only metadata: table names, schemas (column types), partitions, and pointers to the Parquet files in MinIO.

In your on-prem setup, Hive Metastore runs as a service backed by a relational database (typically PostgreSQL or MySQL). That backing database is separate from your application Postgres — it's dedicated to holding the catalog.

When you ingest data with Spark or when Trino runs a query, the first thing that happens is a call to Hive Metastore: "I'm looking for table `analytics.user_events` — where are its files?" Metastore looks in its backing DB and says "those files are in MinIO at `s3a://lakehouse/warehouse/user_events/`, and here's the schema." Without that answer, neither engine knows where to find your tables.

---

## What Breaks When the Hive Metastore Goes Down

When your Hive Metastore crashed this morning, here's what happened:

**Trino queries failed immediately.** Every query needs the metastore to resolve table names and fetch schema. Running `SELECT * FROM analytics.events` returns a "metastore unavailable" error. Dashboards that depend on Trino queries show errors or go blank. Users cannot run ad-hoc queries.

**Spark ingestion jobs failed.** Your nightly ingestion pipelines that read from Postgres and write to Iceberg cannot proceed without metastore access to register new tables or update existing ones. They timeout waiting for a response and crash.

**Debezium CDC cannot write new events** (or they buffer but never commit to Iceberg). Debezium 2.x in streaming mode writes changes via Spark Structured Streaming, which also needs metastore access to stage Parquet files in MinIO.

**dbt transformations failed.** Any dbt job that references Iceberg tables failed at the dbt compile step, when dbt tries to fetch table schemas from the metastore.

**What kept running:** MinIO kept serving files. Your raw Parquet files in MinIO remained untouched and safe. If you had an application that directly read Parquet files from MinIO (without going through Iceberg/metastore), that would have continued to work. But in practice, all your query engines (Trino, Spark, dbt) go through metastore first, so they all stopped.

---

## Your Data Files Are Safe Even When the Metastore Crashes

This is the critical piece: **the Parquet files are still in MinIO and completely untouched.** The metastore crash did not corrupt, delete, or lose any data files.

The metastore only stores metadata — where files live and what columns they have. Iceberg's metadata is also stored in MinIO (as JSON/Parquet "manifest" and "metadata.json" files), so those are also safe.

Think of it this way: the metastore is like a phone book. If the phone book disappears, the phone lines are still working. You just can't find anyone's number. Your data is still in MinIO. Once the metastore is back up, you can reconnect, and all your tables are visible again — Trino will find the files, query them, and serve results just like before.

---

## Making the Metastore Highly Available

Metastore crashes are not acceptable in production. Here's how to prevent one:

**1. Back the metastore with a highly-available RDBMS**

Hive Metastore itself is stateless — it just connects to an RDBMS and runs queries. Use a PostgreSQL or MySQL cluster with replication and failover (not a single box):

- **PostgreSQL approach:** Run 3 PostgreSQL replicas with automated failover (Patroni + etcd for on-prem HA). Keep replication lag under 1 second.
- **MySQL approach:** Similar — use Group Replication or Galera for multi-node HA.

The key: if one node crashes, the others keep serving and elect a new primary. The metastore client transparently reconnects.

> **IMPORTANT**: Pod-level redundancy alone is not enough. Running 3 Hive Metastore pods backed by a single-node Postgres still leaves you with a single point of failure. The backing RDBMS itself must be HA-configured with replication and automatic failover. Both layers (metastore pods AND the RDBMS) must be redundant.

**2. Run multiple Hive Metastore server pods**

Hive Metastore itself should run as multiple replicas in your k8s cluster (e.g., 3 pods). Use a service to load-balance across them. One pod dying doesn't kill the service — the other two keep serving requests. The backing database stays on your highly-available RDBMS.

**3. Configure connection pooling**

Both Spark and Trino connect to metastore via a Thrift client. Enable connection pooling and retry logic:
- Spark config: `spark.sql.catalog.iceberg.pool.connection.*` settings (connection timeout, max retries).
- Trino config: similar settings in the Iceberg catalog properties.

This way, if one metastore pod briefly hiccups, clients retry and hit another pod instead of failing the whole query.

**4. Network-level redundancy**

Your MinIO and Hive Metastore should run on different k8s nodes. Use pod anti-affinity rules so they never concentrate on a single node. If a node goes down, pods redistribute, and services keep running.

---

## What to Back Up (RTO/RPO Implications)

**Back up the Hive Metastore backing RDBMS regularly.** This is the only recoverable source of metadata if the entire metastore database is lost (e.g., storage corruption, operator error).

- **What to back up:** The database schema + all rows in tables like `DBS`, `TBLS`, `COLUMNS`, `PARTITIONS`, `SDS`, etc. (the Hive Metastore schema is well-defined and open-source).
- **How often:** Every 6–12 hours via WAL-level replication (streaming replication of Postgres WAL to an off-cluster backup server). You're paying little incremental cost and get near-zero RPO.
- **Where to store backups:** On-prem object storage (MinIO backup bucket, different from production MinIO), or a separate air-gapped PostgreSQL replica in another data center.

**RTO/RPO implications:**

- **If using HA RDBMS (recommended):** RTO = seconds (failover to replicas is automatic). RPO = < 1 second (replication lag of a healthy replica).
- **If using point-in-time recovery (PITR) from backups:** RTO = tens of minutes (restore from backup, replay WAL, restart metastore pods). RPO = at most 6–12 hours (your backup cadence).

**Do NOT rely on backing up MinIO separately for metastore recovery** — MinIO already has its own replication (assuming you run multiple MinIO nodes, which you should). The metastore backing DB is the single thing that matters for catalog state.

---

## Recovery Steps When the Metastore Goes Down

**Immediate (first 5 minutes — get queries running again):**

1. **Check the Hive Metastore backing database.** SSH to the metastore pod and try connecting to the backing DB. Can you connect? If yes, the DB is up but metastore pods may be stuck. If no, the DB is down.

2. **If the DB is up but metastore pods are not responding:** Restart the metastore pod replicas. Kubernetes will reschedule them. They reconnect to the DB and resume serving.
   ```bash
   kubectl delete pod -n analytics hive-metastore-0 hive-metastore-1 hive-metastore-2
   ```
   Pods restart, reconnect to the backing DB, and metastore is live again. Users can run queries within ~30 seconds.

3. **If the backing database itself is down:** Follow your RDBMS failover procedure (if using HA, this is automatic; if not, promote a replica or restore from backup).

**Short-term (next 1–2 hours — validate):**

4. **Confirm table enumeration:**
   ```sql
   SHOW TABLES FROM iceberg.analytics;
   ```
   Should return your event tables, user tables, etc. If tables are missing, something is more seriously wrong.

5. **Run a sample query on each critical table:**
   ```sql
   SELECT COUNT(*) FROM iceberg.analytics.events;
   ```

6. **Check for recent backups of the metastore DB.** Verify the backup timestamp is recent.

**Medium-term (1–24 hours — prevent recurrence):**

7. **Review the crash logs.** Why did metastore go down?
   - Out of disk on the backing DB? Add storage and set up monitoring.
   - Connection pool exhaustion? Increase pool limits or add more metastore pods.
   - Network partition? Review k8s networking logs.

8. **If you don't have HA on the backing database, build it now.** A single-node Postgres is a single point of failure.

9. **Set up monitoring and alerting:**
   - Metastore pod restarts (Prometheus scrape pod restart count).
   - RDBMS replication lag (should be < 1 second).
   - Alert if metrics exceed thresholds — page on-call before the system is fully down.

---

## Bottom Line

The Hive Metastore is Tier-1 infrastructure in your stack. Its crash cuts off all query access, but does **not** touch or endanger your actual data in MinIO. Treat it like a database: run it on a highly-available RDBMS backend (replicated, with automatic failover), run multiple pod replicas (both must be HA — pods alone are not enough if the backing DB is single-node), back up regularly, and monitor it. RTO should be under 1 minute for failover (HA RDBMS + pod restart), and RPO should be < 1 hour from regular backups. Your data is safe; you're protecting availability and recovery speed, not data loss.
