# Iter 212 Q1 — Trino Coordinator HA on k8s: replicas:2 Won't Work, Here's What Does

## Answer

### What happens if you set `replicas: 2` for the coordinator

**Do not do this.** It creates split-brain worker discovery — a fundamental architectural constraint in OSS Trino 467.

Every worker pod in your cluster points to the same `discovery.uri=http://trino-coordinator:8080` in its `etc/config.properties`. When your coordinator Deployment has `replicas: 2`, the Kubernetes Service round-robins between the two coordinator pods. Both pods believe they are *the* coordinator. Both will register the same set of workers. Both will try to assign tasks. Discovery, scheduling, and query state are completely unsynchronized between them.

The visible symptoms: queries randomly fail with "no nodes available," workers appear and disappear in `system.runtime.nodes`, and you cannot reproduce failures consistently. This is not a config workaround problem — it is inherent to OSS Trino's architecture. Multi-coordinator in one cluster is a roadmap item tracked in trinodb/trino issue #391 (opened 2019, not shipped in Trino 467).

---

### The two real HA patterns

**Pattern A — Two separate Trino clusters behind an external proxy (HAProxy or Envoy)**

Run two complete, independent Trino clusters. Each cluster has its own coordinator pod and its own pool of worker pods. They share nothing at the Trino level (Hive Metastore can be shared). Put a Layer 7 proxy in front of both coordinators, health-checking each on `/v1/info` (HTTP GET, port 8080).

Two sub-options:
- **Active-passive** (recommended for simplicity): proxy sends 100% of traffic to cluster 1. Cluster 2 is idle standby. When cluster 1's health check fails, traffic fails over to cluster 2. In-flight queries on cluster 1 die instantly — clients must retry. The retry lands on cluster 2.
- **Active-active**: both clusters serve traffic concurrently with sticky sessions in the proxy (each query must stay on the same cluster for its lifetime). More complex, but better resource utilization.

**Cost**: roughly doubles worker count. Mitigation: keep cluster 2 at 30% of cluster 1's worker count and autoscale on failover.

**Minimal HAProxy active-passive config:**
```
backend trino_backend
    option httpchk GET /v1/info
    server trino1 trino1:8080 check inter 5s
    server trino2 trino2:8080 check inter 5s backup
```

**Pattern B — Single coordinator + k8s Deployment + PodDisruptionBudget (cost-constrained)**

Run one coordinator pod (replicas: 1). Protect it with three k8s primitives:

1. **Deployment with replicas: 1** so k8s automatically recreates a dead coordinator pod.
2. **PodDisruptionBudget with `minAvailable: 1`** to prevent voluntary evictions during node drains:
   ```yaml
   spec:
     minAvailable: 1
     selector:
       matchLabels:
         app: trino-coordinator
   ```
3. **Readiness probe on `/v1/info`** so the Service does not route traffic to a pod still starting up.

For planned evictions, configure graceful shutdown with `http-server.stop-timeout=60s` in `etc/config.properties` and `terminationGracePeriodSeconds: 90` in the pod spec — in-flight queries finish before the coordinator exits.

Unplanned evictions (OOMKill, node failure) still kill in-flight queries instantly. But planned evictions (node drains during k8s upgrades — your incident) become safe.

---

### In-flight query behavior on coordinator failure

When the coordinator dies, regardless of pattern:

1. **In-flight queries die instantly.** The coordinator holds the entire query state (plan, task graph, stage tracking, exchange buffers). When it dies, all of that is lost. Workers cannot continue alone.

2. **Clients get a connection error** and must re-submit the SQL from scratch.

3. **Workers detect coordinator loss via heartbeat timeout** (~5 minutes by default). Workers abort all running tasks and release resources — including calling `Statement.cancel()` on open Postgres JDBC connections. For federated queries, this means Postgres backends are terminated cleanly (visible in `pg_stat_activity` where the session disappears).

---

### Fault-tolerant execution (FTE) — covers worker failures ONLY

This is a common misconception. Trino's fault-tolerant execution (`retry-policy=TASK`) retries failed tasks on **worker** failures. It does NOT protect against coordinator failure — when the coordinator dies, the query dies regardless of FTE setting.

If your team believes "we have FTE so we're HA" — that is incorrect. FTE is worker resilience. Coordinator HA is Pattern A or Pattern B.

---

### Summary

| Pattern | Cost | Recovery from unplanned eviction | Recovery from planned drain |
|---|---|---|---|
| `replicas: 2` on coordinator | Low | Broken (split-brain) | Broken |
| Pattern A (two clusters + proxy) | High (2× workers) | Automatic failover, in-flight queries die | Same |
| Pattern B (single coord + PDB) | Minimal | k8s recreates pod, in-flight queries die | In-flight queries drain gracefully (up to `stop-timeout`) |
