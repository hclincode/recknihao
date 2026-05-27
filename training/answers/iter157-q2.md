# Iter 157 Q2 — Hive Metastore: Role and SPOF Concerns

## Answer

## Hive Metastore: What It Does and How Critical It Is

### What Hive Metastore Does

The **Hive Metastore is a catalog service** — it tracks "where the tables live." In your Trino + Iceberg + MinIO stack, the Metastore's job is to maintain metadata about your tables: which schema contains which table, and where those tables' underlying metadata files are stored in MinIO.

When you create a table via Trino, the Metastore records it. When you query a table, Trino consults the Metastore to locate the table's Iceberg metadata files (not the data files themselves — those live in MinIO).

### Does Trino Read Metastore on Every Query?

**The resources don't document this in enough detail to give a precise answer.** The resources define the Metastore as the catalog and mention it as part of the stack (alongside Spark for ingestion and Trino 467 for queries), but they don't explicitly document:

- Whether Trino performs a metadata lookup on every single query or caches results
- The connection pool and cache TTL settings relevant to Metastore resilience
- What the failure mode is if the Metastore is unavailable during query execution

This is important operational knowledge that isn't covered in the current resources.

### Single Point of Failure Risk

The Metastore is listed as part of both the ingestion stack and the query stack in your production environment. However, the resources do not detail:

- Whether ongoing queries continue if the Metastore goes down mid-execution
- Whether new queries fail immediately or hang with a timeout
- What the actual blast radius is for a Metastore outage

### What You Should Verify

Given your on-prem Kubernetes deployment:

1. **Test the failure directly**: shut down your Metastore pod and observe:
   - Do long-running queries that started before the outage continue to completion?
   - Do new queries fail immediately or hang waiting for a timeout?
   - How long is the timeout before a query fails?

2. **Check Trino configuration**: look at your coordinator's `catalog/iceberg.properties` — there may be connection pool settings, retry counts, or cache TTLs that control Metastore resilience.

3. **Consider running Metastore HA**:
   - Run multiple Metastore replicas in Kubernetes with a load balancer in front
   - Back it with a high-availability database (if not already)
   - Use DNS-based failover so Trino reconnects automatically

The resources don't yet cover operational resilience for the Metastore, which is important for an on-prem SaaS deployment. The platform team should document how to deploy it for HA, what the real-time cost of an outage is, and what caching/retry strategies Trino should use.
