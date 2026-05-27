# Answer to Q2: Iceberg Connector Has No Metastore Cache — By Design (Iter 331)

Yes, your team is correct — the Hive connector caches metastore partition listings but the Iceberg connector intentionally does not. Here's why, and what to do about it.

## The Hive vs. Iceberg Caching Distinction

**The Hive connector DOES cache HMS partition listings** via `hive.metastore-cache-ttl`. Those listings can be expensive to fetch (sometimes millions of rows for large tables), so caching gives a significant speed-up for Hive table queries.

**The Iceberg connector intentionally does NOT cache HMS results.** This is by design, not a limitation. Trino's Iceberg connector calls the Hive Metastore once per table per query at planning time, every single time (tracked in trinodb/trino#13115).

## Why No Caching for Iceberg?

**Snapshot consistency.** In Iceberg, HMS stores only a single pointer per table — the S3 path to the current `metadata.json` file in MinIO. That pointer changes every time a Spark write commits a new snapshot. If Trino cached this pointer, it would serve stale snapshots and miss concurrent writes from Spark ingestion jobs. Iceberg's entire concurrency model depends on every reader picking up the current pointer at query plan time.

This is the right tradeoff: a Hive partition listing is expensive to fetch but changes rarely. An Iceberg metadata pointer is cheap to fetch but changes on every write.

## The Good News: The HMS Call Is Actually Cheap

The HMS call for Iceberg is **not expensive**:
- It's a single Thrift RPC returning one string (the S3 path to metadata.json).
- Wire time is typically **<10 ms** when HMS is healthy.

This is very different from the Hive connector fetching partition rows. **So why are you seeing 5-10 second pauses?**

The pause is not caused by the absence of caching — it's a sign that something upstream (HMS health, HMS backing database, network) is slow:

1. **HMS health** — HMS pods under memory pressure, GC pauses, or the backing Postgres database overloaded will make every query startup hang.
2. **Single HMS pod (SPOF)** — If you're running one HMS pod, any restart or OOM blocks all new Iceberg queries.
3. **Network latency** — If HMS isn't in the same k8s cluster or has network policy overhead, every query pays that RTT.

## Practical Solutions

**Short term — diagnose where the pause is:**
```sql
-- Check phase timings on recent queries
SELECT query_id, analysis_time_ms, planning_time_ms, execution_time_ms
FROM system.runtime.queries
ORDER BY create_time DESC
LIMIT 20;
```
If `analysis_time_ms` or `planning_time_ms` is 5+ seconds, that's HMS/planning time — not data scan time.

**Check HMS health:**
```bash
kubectl logs -l app=hive-metastore -n <namespace> --since=1h | grep -i error
kubectl get pods -l app=hive-metastore -n <namespace>
```

**Medium term — make HMS HA:**
Three stateless HMS pods + HA Postgres backend. Configure Trino with comma-separated URIs for failover:
```properties
# iceberg.properties
hive.metastore.uri=thrift://hms-0.hive-metastore:9083,thrift://hms-1.hive-metastore:9083,thrift://hms-2.hive-metastore:9083
```

**Long term — migrate to a REST catalog:**
If HMS remains operationally painful, migrating to an Iceberg REST catalog (Polaris, Lakekeeper, Nessie) eliminates this SPOF. REST catalogs are HTTP APIs designed specifically for Iceberg — stateless and easier to scale than HMS + Postgres. Migration requires re-registering tables but gives a simpler operational surface.

## Bottom Line

The Hive connector's partition cache solves a different problem than what you're hitting. Your Iceberg HMS call is cheap by design — if it's taking 5-10 seconds, focus on HMS health and HA, not on adding a cache that would break snapshot consistency.

**Resources cited:** `/Users/hclin/github/recknihao/resources/21-hive-metastore-iceberg.md`, `/Users/hclin/github/recknihao/resources/18-query-performance-regression.md`
