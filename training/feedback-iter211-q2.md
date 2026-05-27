# Feedback — Iter 211 Q2 (Trino federation / coordinator HA on k8s)

## Question recap
We're setting up a second Trino coordinator for HA on k8s. How does Trino route queries between two coordinators? Active-active or active-passive? If the active coordinator goes down mid-query, does the other pick it up? How does this affect federated queries (Iceberg + Postgres)?

## Score: 3.375 / 5 (FAIL general ≥3.5; FAIL Trino federation raised ≥4.5)

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3.5 | What the answer states is directionally correct (coordinator stateful, in-flight queries die on coordinator failure), but it misses the central architectural fact: OSS Trino does NOT natively support multiple coordinators in one cluster. Workers register against one `discovery.uri`. So "two coordinators" actually means two separate Trino clusters fronted by an external proxy (HAProxy/Envoy), OR active-passive with manual failover — NOT two coordinators sharing the same worker pool. The answer hints at "hot standby" but never grounds the recommendation in the architectural constraint. |
| Beginner clarity | 4.5 | Well-organized, distinguishes "what resources cover" vs "what they don't", names the analogy to HMS HA correctly, accessible. |
| Practical applicability | 3.0 | The interim "treat second coordinator as hot standby; configure k8s Service to route all traffic to one coordinator" advice is actually right, but the engineer has no concrete k8s pattern (HAProxy/Envoy/Service swap), no idea why two coordinators-in-one-cluster doesn't work, and no story for federation queries specifically. |
| Completeness | 2.5 | Defers most of the question to "verify in docs." Misses: (a) OSS Trino single-coordinator-per-cluster constraint; (b) HAProxy/Envoy proxy pattern as the actual deployed "HA"; (c) fault-tolerant execution (`retry-policy=TASK`) as separately addressing WORKER failures (not coordinator); (d) federation-specific in-flight behavior (Postgres JDBC connections held by workers, Iceberg file scans on workers, OPA decision already made at planning); (e) graceful coordinator shutdown / draining. The federation lens in particular got under-served. |

## What is verifiably correct vs wrong vs missing

### Verified correct (per trino.io docs, GitHub #391, query-resiliency docs)

- **Coordinator is stateful / in-flight queries die on coordinator failure**: VERIFIED. From github.com/trinodb/trino/issues/391: "if a coordinator crashes, all queries managed by that coordinator fail."
- **No automatic resumption on a new coordinator**: VERIFIED. The proposed multi-coordinator + dispatcher architecture in issue #391 is a roadmap item; not shipped in OSS Trino 467.
- **"HA in Trino means new queries can be accepted after failover, not in-flight survival"**: directionally correct framing.
- **OPA already authorized at analysis time, so the auth decision isn't re-evaluated**: correct.
- **Worker-side Postgres JDBC connections aborted on coordinator failure**: correct in effect (workers cannot complete tasks if their coordinator is gone).

### Critical missing fact

- **OSS Trino does not natively support multiple coordinators in a single cluster.** Each Trino cluster has exactly one coordinator; workers register against a single `discovery.uri` pointing to that coordinator. The answer never states this. As a result, the engineer's premise ("setting up a second Trino coordinator for HA on k8s") is ambiguous and the answer doesn't disambiguate:
  - Option A: Two separate Trino clusters (each with its own coordinator + workers) fronted by HAProxy / Envoy / k8s Service. This is the deployed OSS HA pattern (Arenadata, Goldman Sachs Envoy-based blog).
  - Option B: Active-passive single coordinator with a standby pod waiting for k8s to reschedule. This is what k8s Deployment + readiness probes give you naturally.
- The answer's "hot standby; route all Service traffic to one coordinator" recommendation is *the right interim advice* but isn't grounded in the architectural reason.

### Missing nuance

- **Fault-tolerant execution** (`retry-policy=TASK` or `QUERY` with an exchange manager spooling to MinIO) addresses WORKER node failures, not coordinator failures. Mentioning it is important so the engineer doesn't think enabling FTE buys coordinator HA.
- **Federation-specific failure behavior**: when the coordinator dies mid-query,
  - Postgres JDBC connections opened by workers are torn down when worker tasks abort (workers detect coordinator gone via heartbeat).
  - Iceberg file scans on workers also abort.
  - No partial results commit to the client.
  - There is no "the second cluster picks up the query and re-reads from the same Iceberg snapshot." A retry is a brand-new query against possibly a different Iceberg snapshot if a commit landed in between.
- **OPA decision log entry**: the denied/allowed decision is already in the OPA log even if the query later fails — useful for incident forensics.
- **k8s patterns**:
  - PodDisruptionBudget on coordinator
  - Coordinator graceful shutdown (in newer Trino: `shutdown.grace-period`, but for coordinator specifically you typically drain by setting node to non-coordinator and waiting)
  - Readiness probe behavior during failover
  - HAProxy / Envoy upstream config (active-passive backend with health check on `/v1/info`)

### What the answer did well

- Honestly admitted the resource gap rather than fabricating content — this is the correct failure mode and avoids the "confident wrong" pattern that has dragged the topic average down (iter163 connection-pool, iter169 ALTER CATALOG, iter171 named flush_metadata_cache, iter209 OPA mid-query, iter210 OPA batched-uri).
- Correctly stated the in-flight-queries-die fact and the OPA-already-authorized fact.
- The "treat second coordinator as hot standby until you verify behavior" operational guidance is actually correct interim advice, even though it's not grounded in the architectural reason.

## Resource fix recommendations (priority order)

### HIGH (critical resource gap — coordinator HA is a NEW gap)

Add a new section to `resources/22-trino-federation-postgresql.md` (or a new file `resources/24-trino-coordinator-ha-on-k8s.md`) covering:

1. **OSS Trino single-coordinator-per-cluster constraint**: state plainly that one Trino cluster has exactly one coordinator. Workers register against one `discovery.uri`. You cannot run two coordinators sharing the same workers in OSS Trino 467.
2. **The two real "HA" patterns**:
   - **Two separate clusters + external proxy**: HAProxy / Envoy / k8s Ingress in front of two Trino clusters. Each cluster has its own coordinator + workers + catalog config. The proxy does health checking on `/v1/info` and fails over. Active-passive (one cluster takes traffic at a time) is the simpler pattern; active-active requires sticky-session-by-query-id and is brittle because the client must always reach the same coordinator that owns its query. Cite Arenadata docs (https://docs.arenadata.io/en/ADH/current/how-to/trino/trino-ha.html) and the Goldman Sachs Envoy-proxy blog (https://developer.gs.com/blog/posts/enabling-highly-available-trino-clusters-at-goldman-sachs) as the public references.
   - **Single coordinator + k8s rescheduling**: k8s Deployment with `replicas: 1`, readiness probe, PodDisruptionBudget. Pod gets rescheduled on failure; in-flight queries die; clients retry. This is the "do less" HA option and is often what teams actually need.
3. **In-flight queries die on coordinator failure — period**: cite trinodb/trino issue #391 verbatim and explain why (coordinator holds the query state machine, task scheduling, exchange coordination — workers can't complete tasks without it).
4. **Fault-tolerant execution is for WORKER failures only**: `retry-policy=TASK` and `QUERY` with an exchange manager spooled to MinIO addresses WORKER-side faults. Enabling FTE does NOT buy coordinator HA.
5. **Federation-specific behavior on coordinator failure**:
   - Worker JDBC connections to Postgres are torn down when the worker's task aborts.
   - Iceberg file scans on workers abort; no partial commits to client.
   - OPA decision already in OPA's decision log (auth happened at analysis on the now-dead coordinator).
   - Client retry is a brand-new query; if an Iceberg snapshot commit landed in between, the retry may see different data.
6. **Future roadmap**: trinodb/trino issue #391 outlines multi-coordinator with shared/distributed dispatcher; not in OSS 467. Mention as context so engineers don't expect it.

### MEDIUM (k8s-specific operational detail)

Add to the new section:
- PodDisruptionBudget example for coordinator.
- Graceful shutdown semantics (`SHUTDOWN` SQL command at `/v1/info/state`, the `node-scheduler.include-coordinator` flag, the realistic statement "for coordinator there is no clean drain; in-flight queries fail and clients must retry").
- Readiness probe on `/v1/info` returning `starting`/`active`/`shutting_down`.
- HAProxy config snippet for active-passive: one backend marked `backup`, health check on `/v1/info`.

### LOW (linkage to existing content)

Cross-link from the new HA section to:
- §8.4 OPA decision logs (auth decisions survive coordinator failure, useful for forensics).
- Event listener section (QueryCompletedEvent does NOT fire when coordinator dies — the engineer's audit trail has a gap during the failure window).

## Iter 212 angle suggestions

1. **Re-test coordinator HA after the resource fix lands** with a different phrasing — e.g., "Can I run our Trino coordinator pod as a Deployment with replicas=2 in k8s?" (tests whether the responder absorbs the single-coordinator-per-cluster constraint).
2. **Cross-three-source federation**: Iceberg + Postgres + a second catalog (MySQL or second Postgres). Plan complexity, broadcast vs partitioned join choice when one side is on Postgres and the other on Iceberg, with a third small dimension on a second JDBC.
3. **OPA mid-query lifecycle re-test with different surface phrasing**: "Does my OPA decision log entry appear before or after the workers start reading Iceberg data?" — tests whether the iter209 OPA-at-analysis-time fix has fully landed in the responder's mental model.
