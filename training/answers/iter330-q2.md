# Answer to Q2: HMS Tuning for Multi-Tenant Trino — Why Queries Are Slow to Start (Iter 330)

## What HMS is and why it's slowing your startup

**HMS** stands for **Hive Metastore**. Think of it as the "directory listing" for your Iceberg tables — it's not a data storage system, but a **catalog service** that Trino contacts to find where each table's metadata lives.

Here's the critical insight: **every single new query you run must contact HMS first**, before any data gets read. That 5-10 second delay you're seeing is almost certainly HMS responding slowly.

When you submit a query to Trino:
1. Trino needs to know: "Where is the current metadata file for this table?"
2. **Trino contacts HMS** (via Thrift RPC on port 9083) and asks this question
3. HMS does a database lookup and returns an S3 path to your metadata file in MinIO
4. Trino then reads that metadata from MinIO and plans the query

This happens **for every new query, every time**. The Iceberg connector does NOT cache this result — the call is fast when healthy (<10 ms typically) but always on the critical path.

## Configuration knobs to check when startup is slow

### 1. Is HMS itself responsive?

Check if HMS pods are running and healthy:
```bash
kubectl get pods -n <your-namespace> -l app=hive-metastore
kubectl logs -l app=hive-metastore -n <namespace> --since=1h | grep -i error
```

Look at:
- **JVM heap size** on the HMS pod. Default is often too small for 80 tenants worth of tables.
- **Garbage collection pauses** — if HMS is doing long GC pauses, even fast queries see 10-second hangs at startup.

### 2. Is the backing Postgres database slow?

**This is the real bottleneck in most cases.** HMS itself is stateless — it just queries a Postgres or MySQL database for each lookup. If Postgres is slow, HMS waits, and your queries hang.

Check:
- **Postgres connection pool** — is HMS exhausting available connections? If the pool is too small, new HMS requests queue.
- **Postgres disk I/O** — if Postgres is swapping or doing slow disk I/O, even a simple one-row lookup takes seconds.
- **Postgres replication lag** (if using HA) — a slow replica can cause query planning delays.

Verify connections: `SELECT count(*) FROM pg_stat_activity;`

### 3. HMS is a SPOF — Is it HA?

If you only have **one HMS pod**, any pod restart, OOM, or network hiccup blocks all new queries. Check:

```bash
kubectl get deployment hive-metastore -o yaml | grep replicas:
```

If it shows `replicas: 1`, **every query serializes through one pod.** With 80 tenants, this becomes a bottleneck quickly.

### 4. Network connectivity between Trino and HMS

If Trino and HMS pods are on different Kubernetes nodes:
- Check network latency between nodes (should be <5 ms on a LAN)
- Verify DNS resolution — is `hive-metastore` service resolving quickly?

## Diagnosis workflow: confirm HMS is the culprit

Use Trino system tables to isolate where the delay is:

```sql
-- Check recent queries and their timing breakdown
SELECT query_id, state, queued_time_ms, analysis_time_ms, planning_time_ms, execution_time_ms
FROM system.runtime.queries
WHERE state = 'FINISHED'
ORDER BY create_time DESC
LIMIT 20;
```

- If `analysis_time_ms` or `planning_time_ms` is 5+ seconds — that's HMS/planning time
- If `queued_time_ms` is high — queries are waiting for resources, not HMS
- If `execution_time_ms` is high — it's data read time, not startup

## Priority order for fixes

1. **Check HMS pod logs for errors** — OOM events, GC pauses, Postgres connection failures
2. **Verify Postgres health** — connection limits, disk I/O, replication lag
3. **Make HMS HA** — run 3 HMS pods behind a Kubernetes Service with HA Postgres backend if currently at `replicas: 1`
4. **Long term: consider a REST catalog** — switching to an Iceberg REST catalog (Polaris or Lakekeeper) eliminates this SPOF entirely, but that's a migration project

**Start with checking HMS pod health and Postgres responsiveness — that's where 90% of startup slowness comes from.**

**Resources cited:** `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md`, `/Users/hclin/github/recknihao/resources/18-query-performance-regression.md`
