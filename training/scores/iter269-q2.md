# Score: iter269-q2

**Score**: 4.56 / 5.0
**Pass**: YES (pass threshold: 4.50)

## Dimension scores
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.25 | Core claims about FTE scope are correct: FTE protects against worker failures only, not coordinator failures; coordinator holds query state in memory; queries die on coordinator crash regardless of FTE. `retry-policy=TASK` vs `QUERY` distinction is accurate. `exchange-manager.name=filesystem` is the correct property value. Local filesystem exchange correctly flagged as non-production (matches docs verbatim). Multi-coordinator unavailable in OSS Trino is accurate. **Notable error**: `http-server.stop-timeout` is not a documented Trino property; the canonical graceful shutdown property is `shutdown.grace-period`. More importantly, Trino's graceful shutdown API is **worker-only** — it does NOT apply to the coordinator. So suggesting `http-server.stop-timeout=60s` on the coordinator to give active queries time to finish is misleading; even with proper config, a coordinator shutdown still kills running queries. PDB and dual-cluster HA pattern are valid. |
| Beginner clarity | 4.75 | Excellent opening with a direct, plain-English answer to the engineer's confusion ("FTE does NOT change that"). Failure-type summary table at the bottom is highly accessible. Distinction between worker failure and coordinator failure is explained mechanically (query state held in coordinator memory). Jargon like "PodDisruptionBudget" is shown with concrete YAML. No assumed OLAP knowledge required. |
| Practical applicability | 4.75 | Engineer can act immediately: complete FTE config blocks, MinIO endpoint matches their stack (`minio.minio.svc.cluster.local:9000`), PDB YAML is ready to apply, dual-cluster HA pattern named with specific tools (HAProxy/Envoy/Trino Gateway). The "Practical Defense" section maps directly to the engineer's stated symptoms (OOMKill, random node failure, customer-facing exports). Even the misguided `http-server.stop-timeout` suggestion still nudges them toward terminationGracePeriodSeconds, which is the right k8s lever. Postgres tcp_keepalives_idle tip is a nice bonus. |
| Completeness | 4.50 | Addresses every part of the question: what FTE is, what it protects against, whether it helps coordinator failures (no), how to set it up, and what alternatives exist. Includes downstream effects (Postgres connection cleanup, Iceberg snapshot isolation) the engineer didn't ask about but will encounter. Missed nuance: doesn't mention that Trino's graceful shutdown is worker-only, so the coordinator graceful-shutdown subsection over-promises. Doesn't mention Trino Gateway as a first-class option in detail (only listed in passing). |
| **Average** | **4.56** | |

## What the answer got right
- FTE scope clearly bounded: workers only, not coordinator (verified against trino.io/docs/current/admin/fault-tolerant-execution.html).
- `retry-policy=TASK` vs `QUERY` recommendation matches official guidance (TASK for large batch queries, QUERY for many small queries).
- `exchange-manager.name=filesystem` is the correct property; `exchange.base-directories`, `exchange.s3.endpoint`, `exchange.s3.path-style-access` all match Trino S3 exchange config.
- Correctly states local filesystem exchange is non-production only (matches docs verbatim).
- Correctly notes multi-coordinator HA is not native to OSS Trino; correctly recommends dual-cluster pattern (matches Goldman Sachs / Trino Gateway prior art).
- Correctly states coordinator failure kills all running queries regardless of FTE — explanation of why (coordinator holds plan/task graph/stage state) is mechanically accurate.
- MinIO endpoint and credentials configuration matches the engineer's on-prem stack (per prod_info.md).
- Failure-type summary table is a highly effective recap.
- Bonus context on Postgres connection cleanup and Iceberg snapshot isolation is accurate and useful.

## Gaps or errors
- **`http-server.stop-timeout` is not a documented Trino property.** Verified against trino.io/docs/current/admin/properties-http-server.html — no such property exists. The standard graceful shutdown property is `shutdown.grace-period` (default 2 minutes).
- **Trino graceful shutdown does NOT apply to the coordinator.** Per Trino docs and community discussions, the shutdown API is worker-only. The answer's claim that "planned evictions (node maintenance, upgrades) give active queries 60 seconds to finish" on the coordinator is incorrect — even with grace period config, coordinator shutdown still aborts running queries. This is a meaningful inaccuracy that could mislead the engineer into thinking they have coordinator-side resilience when they don't.
- The dual-cluster Option B should mention Trino Gateway by name more prominently — it is the canonical open-source solution for this pattern (briefly mentioned but not emphasized).
- Does not mention that resources downscaling / OOM root cause investigation should look at `query.max-memory-per-node` and JVM heap before just increasing pod memory.

## Verified sources
- [Fault-tolerant execution — Trino 481 Documentation](https://trino.io/docs/current/admin/fault-tolerant-execution.html)
- [HTTP server properties — Trino 480 Documentation](https://trino.io/docs/current/admin/properties-http-server.html) (confirms `http-server.stop-timeout` is NOT documented)
- [Graceful shutdown — Trino 481 Documentation](https://trino.io/docs/current/admin/graceful-shutdown.html) (confirms worker-only graceful shutdown via `shutdown.grace-period`)
- [Does Trino support having multiple coordinators? — Discussion #15230](https://github.com/trinodb/trino/discussions/15230) (confirms no native multi-coordinator HA in OSS)
- [Enabling Highly Available Trino Clusters at Goldman Sachs](https://developer.gs.com/blog/posts/enabling-highly-available-trino-clusters-at-goldman-sachs) (confirms Envoy/proxy + multi-cluster as the production HA pattern)
- [Improve query processing resilience — Trino 481 Documentation](https://trino.io/docs/current/installation/query-resiliency.html) (FTE + retry-policy guidance)
