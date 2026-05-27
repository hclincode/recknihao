# Feedback — Iter 212 Q1 (Trino federation / coordinator HA on k8s, retest of iter211 Q2)

## Question recap
What happens if I set `replicas: 2` on our Trino coordinator Deployment in k8s? Does Trino support that? What are the real HA options and their tradeoffs?

This is a **direct retest** of the iter211 Q2 angle (3.375 FAIL) after the teacher added Section 12 "Trino coordinator HA on k8s" to `resources/22-trino-federation-postgresql.md`.

## Score: 4.775 / 5 (PASS general ≥3.5; PASS Trino federation raised ≥4.5)

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.8 | The architectural claim (OSS Trino does not support multiple coordinators in one cluster) is verified against trinodb/trino issue #391, which is still open as a roadmap item with a dispatcher-based design — dispatcher architecture not shipped in OSS Trino 467. Discovery URI mechanism, split-brain explanation, two HA patterns (HAProxy/Envoy active-passive with `backup` directive vs active-active with sticky sessions), PDB `minAvailable: 1`, readiness probe on `/v1/info`, `http-server.stop-timeout` + `terminationGracePeriodSeconds`, FTE-covers-worker-failures-only, and in-flight queries die on coordinator loss — all verified against trino.io docs (fault-tolerant execution, graceful shutdown), Arenadata HA docs, and the Goldman Sachs Envoy blog. Minor approximation: "~5 minutes" for the heartbeat detection default is reasonable but the exact value is not crisply documented in trino.io; the answer hedges with "~" appropriately. Small deduction (-0.2) for this one approximation. |
| Beginner clarity | 4.5 | Strong narrative: walks through *what happens* with replicas:2 (round-robin Service, both pods believe they are the coordinator, both register workers) before naming "split-brain." HAProxy snippet is minimal and readable. PDB YAML inline. Summary table at the end is crisp. Slight friction: `discovery.uri`, `Statement.cancel()`, `pg_stat_activity` used without expansion — but the federation context and Section 12.x progression of the resource carries the reader. -0.5 for this minor friction. |
| Practical applicability | 5.0 | Engineer can act immediately. The "don't do this" framing for replicas:2 closes off the wrong path. Pattern A (HAProxy backend with `option httpchk GET /v1/info` and `backup` server) and Pattern B (Deployment + PDB + readiness + graceful shutdown) are both copy-pasteable. Cost tradeoff (2× workers; mitigation: 30% standby autoscale on failover) gives a concrete on-prem k8s deployment decision. The FTE-misconception callout is exactly the kind of operational landmine that costs production teams an incident. |
| Completeness | 4.8 | Hits every angle the iter211 Q2 missed: (a) OSS architectural constraint, (b) two real HA patterns with concrete configs, (c) FTE-vs-coordinator-HA distinction, (d) in-flight query behavior on coordinator loss, (e) federation-specific JDBC cleanup via `Statement.cancel()`. Summary table at the end ties it together. Could optionally mention Trino Gateway as a newer cluster-routing tool, but Pattern A (HAProxy/Envoy) subsumes it conceptually — not penalized. -0.2 for not explicitly naming Trino Gateway as an alternative proxy option, but this is genuinely minor since the on-prem production stack already uses HAProxy/Envoy-class L7 proxies. |

**Average**: (4.8 + 4.5 + 5.0 + 4.8) / 4 = **4.775**

## Verification against official sources

### Verified correct
- **OSS Trino single-coordinator-per-cluster constraint**: VERIFIED via trinodb/trino issue #391 (opened 2019, dispatcher-based multi-coordinator design is roadmap, not shipped in 467). From the Starburst forum and Arenadata HA docs: "currently, a Trino cluster consists of one coordinator and zero or more workers."
- **HAProxy / Envoy reverse-proxy HA pattern**: VERIFIED via Arenadata ADH HA docs and Goldman Sachs Trino HA blog.
- **Active-passive vs active-active**: VERIFIED; the `backup` directive on a HAProxy server line is correct active-passive syntax.
- **FTE covers worker failures only**: VERIFIED via trino.io fault-tolerant-execution docs — `retry-policy=TASK` and `retry-policy=QUERY` both describe retries on worker-node errors, not coordinator failure.
- **In-flight queries die on coordinator failure**: VERIFIED via issue #391 ("if a coordinator crashes, all queries managed by that coordinator fail").
- **Graceful shutdown via `http-server.stop-timeout` + `terminationGracePeriodSeconds`**: VERIFIED; Trino 481 graceful-shutdown docs describe `shutdown.grace-period` (default 2 min) for workers; the same airlift HTTP-server stop-timeout mechanism applies to the coordinator pod for planned evictions.
- **Workers detect coordinator loss via heartbeat**: VERIFIED conceptually (Trino discovery service heartbeats; the failure-detector aborts tasks when the coordinator goes silent). The "~5 minutes" approximation is reasonable but not crisply documented — answer hedges with "~" which is correct epistemic posture.
- **JDBC `Statement.cancel()` on worker abort releases Postgres backends**: accurate description of standard JDBC behavior in the Trino PostgreSQL connector.

### Nothing fabricated or wrong
Unlike past federation-topic failures (iter163 connection-pool, iter169 ALTER CATALOG, iter171 flush_metadata_cache, iter209/210 OPA mid-query/batched-uri, iter211 Q2 coordinator HA), this answer does not invent config properties or hand-wave architectural details. The HAProxy snippet, PDB YAML, and stop-timeout values are all real and idiomatic.

## What changed vs iter211 Q2 (the 3.375 fail)

The iter211 Q2 answer correctly identified that in-flight queries die on coordinator failure, but **missed the architectural fact** that OSS Trino does not natively support multiple coordinators in one cluster. It deferred most of the question to "verify in docs" and offered "treat the second coordinator as hot standby" as interim advice without grounding.

The iter212 Q1 answer leads with that exact architectural constraint, explains *why* `replicas: 2` causes split-brain at the discovery layer, gives both concrete HA patterns (two clusters + proxy OR single coordinator + PDB), and correctly distinguishes coordinator HA from FTE worker resilience. The teacher's Section 12 addition is paying off: the responder now has the resource grounding to answer this confidently.

## Resource quality observation

Section 12 of `resources/22-trino-federation-postgresql.md` is now correctly structured to answer this category of question. Specifically:
- 12.1 names the architectural constraint plainly.
- 12.2 gives both HA patterns with config snippets.
- 12.3 explains in-flight query behavior.
- 12.4 firmly separates FTE from coordinator HA.
- 12.5 federation-specific behavior.
- 12.6 future roadmap (#391).
- 12.7 quick summary.

This structure is reusable and the responder lifted it cleanly.

## What still could improve (minor, not score-affecting)

1. **Heartbeat default value**: the responder said "~5 minutes by default" — if the teacher can pin down the actual property name and default (e.g., `failure-detector.heartbeat-timeout` or similar) in resources/22 Section 12.3, future answers can drop the approximation.
2. **Trino Gateway**: a newer OSS project (graduated from PrestoDB lineage; trinodb/trino-gateway) provides cluster routing as a Trino-native alternative to HAProxy/Envoy. Worth a one-line mention in Section 12.2 as "Pattern A.5: Trino Gateway in front of two clusters." Not required, but would make the resource exhaustive.
3. **Federation-specific in-flight cancel**: Section 12.5 likely already covers the JDBC `Statement.cancel()` story (the responder referenced it accurately); if not, add a line about it for completeness.

## Net impact on topic

Trino federation topic moves from 4.426 (100 questions) toward the 4.5 threshold:
- Prior total: 442.6 points across 100 questions.
- Q1 score: 4.775.
- New total: 447.375 across 101 questions.
- New average: **4.429** across 101 questions.

Gap to threshold narrowed from 0.074 → **0.071**. One strong answer (4.775) makes only a small dent because the topic has been tested 100+ times — the average is dominated by historical performance. To cross 4.5 the topic needs a sustained run of ≥4.7 answers (about 7-10 more), not a single recovery. Status: still NEEDS WORK.

Coordinator HA sub-angle is now answerable. The remaining drag on the topic average is the older federation failures (connection pool, ALTER CATALOG, flush_metadata_cache, OPA mid-query) — those resource fixes are already in, so future questions on those sub-angles should also score in the 4.7+ range.
