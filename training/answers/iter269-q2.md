# Iter269 Q2 — What Happens When the Trino Coordinator Crashes Mid-Query

## Answer

The short answer is: when your coordinator pod dies, every running query dies with it — and Fault-Tolerant Execution (FTE) does NOT change that. This is the most common point of confusion about FTE.

### What FTE Actually Protects Against

FTE with `retry-policy=TASK` handles **worker failures**, not coordinator failures.

When a **worker** crashes mid-query:
1. Trino detects the failure
2. Retries only the failed task on another surviving worker
3. Reuses intermediate results already spooled to the exchange store (MinIO)
4. The query continues without restarting from scratch

This is valuable for long-running exports. One bad worker pod doesn't kill a multi-hour job.

### Why Coordinator Failure Is Different

When the **coordinator** crashes:
- All query state dies immediately — the coordinator holds the entire query plan, task graph, stage tracking, and worker assignments in memory
- Workers cannot continue — they take instructions from the coordinator and don't have enough context to proceed independently
- Clients receive connection errors and must retry from scratch
- The new coordinator has an empty query registry — dead query IDs are not recoverable
- This happens regardless of FTE configuration

**FTE does not help coordinator failures. There is no workaround at the OSS Trino level.**

### FTE Configuration (For Worker Resilience)

If you want FTE to protect long exports from worker failures:

**Step 1: Set retry policy**

```properties
# etc/config.properties on coordinator AND all workers
retry-policy=TASK
```

Use `retry-policy=TASK` (not `QUERY`) for long federated exports:
- `TASK`: retries only the failed task, reuses completed work — much faster for large queries
- `QUERY`: restarts the entire query from scratch — only suitable for many small short queries

**Step 2: Configure exchange manager to MinIO (CRITICAL)**

```properties
# etc/exchange-manager.properties on coordinator AND all workers
exchange-manager.name=filesystem
exchange.base-directories=s3://trino-exchange/
exchange.s3.region=us-east-1
exchange.s3.endpoint=http://minio.minio.svc.cluster.local:9000
exchange.s3.path-style-access=true
exchange.s3.aws-access-key=${ENV:MINIO_ACCESS_KEY}
exchange.s3.aws-secret-key=${ENV:MINIO_SECRET_KEY}
```

**Never use local filesystem for exchange in production.** Trino's docs explicitly mark local filesystem exchange as non-production only. On a multi-worker cluster, a per-pod `emptyDir` loses intermediate results when tasks retry on a different worker — defeating the entire purpose of FTE. You must use MinIO (which your stack already has).

### Protecting Against Coordinator Failure

Since FTE doesn't help, you need one of two approaches:

**Option A: Kubernetes reliability (most common for on-prem)**

Keep one coordinator pod and harden it against voluntary evictions:

```yaml
# PodDisruptionBudget: prevents voluntary evictions without a replacement ready
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: trino-coordinator-pdb
spec:
  minAvailable: 1
  selector:
    matchLabels:
      component: trino-coordinator
```

Also add graceful shutdown settings so planned evictions (k8s upgrades) give queries time to finish:

```properties
# etc/config.properties
http-server.stop-timeout=60s
```

```yaml
# Kubernetes deployment
terminationGracePeriodSeconds: 90
```

Result: planned evictions (node maintenance, upgrades) give active queries 60 seconds to finish. Unplanned crashes still kill queries instantly — but they're rarer.

**Option B: Two clusters behind a load balancer**

Run two independent Trino clusters. Use a load balancer (HAProxy, Envoy, or Trino Gateway) to route queries. When one coordinator fails, health checks detect it and route new queries to the other cluster. In-flight queries on the dead cluster still die, but new queries continue. This is the production HA pattern for critical workloads.

Do not run two coordinator pods in the same cluster — this causes split-brain worker discovery issues. Each HA cluster needs its own independent set of workers.

### Practical Defense for Your Export Workload

1. **FTE with `retry-policy=TASK` + MinIO exchange** — protects against worker failures during long exports. If a worker pod dies, failed tasks retry on another worker without re-scanning Postgres or replanning Iceberg.

2. **Schedule exports during low-traffic hours** — coordinator crashes are rare; minimizing load during exports reduces unplanned pod pressure.

3. **Client-side retry with backoff** — catch connection errors (502/503, TCP reset) and retry with exponential backoff. Most coordinator restarts take 15–30 seconds; a client that retries after 30s often succeeds.

4. **Monitor coordinator pod stability** — if the coordinator is OOMKilled repeatedly, it needs more memory (`resources.limits.memory` in the Deployment spec), not FTE configuration.

### What Happens to Postgres and Iceberg After a Crash

**Postgres connections**: Workers cancel open JDBC statements and close connections cleanly when they detect the coordinator is gone. Occasional stuck sessions can occur during abrupt crashes — configure `tcp_keepalives_idle=60` on the Postgres server to auto-close stale connections.

**Iceberg snapshots**: Queries pin a specific Iceberg snapshot at plan time. When the query dies, that snapshot is unaffected (snapshots are immutable). If the user retries later, they may see a newer snapshot if commits happened in the interim — this is normal Iceberg snapshot isolation, not a bug.

### Summary

| Failure Type | FTE Helps? | What to Do |
|---|---|---|
| Worker pod crashes mid-query | YES (`retry-policy=TASK` + MinIO) | Configure FTE |
| Worker pod is evicted | YES | Configure FTE |
| Coordinator pod crashes | NO | Kubernetes PDB + graceful shutdown; or dual-cluster HA |
| Coordinator OOMKilled | NO | Increase coordinator memory limit |

FTE is a significant improvement for large federated queries — a single bad worker no longer kills a multi-hour export. But for coordinator HA, the answer is at the infrastructure level (Kubernetes reliability, dual clusters), not at the Trino configuration level.
