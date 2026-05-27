# Iter 219 Q2 Judge Score

## Score: 4.80

## Topic: Trino federation cross-source connectors

## What the answer got right

- **Reframes the question as "find the smoking gun first"** rather than jumping to "yes ingest" — exactly what the engineer asked for ("how do I know federation is the problem"). The 5-signals structure is ranked by clarity of evidence, which gives the engineer a triage order.
- **Signal 1 (Postgres CPU on the replica)** is the correct first place to look — points to `pg_stat_activity` filtered by the Trino-connector user, with a concrete 70% sustained threshold. This is the kind of operational specificity an oncall engineer can act on immediately.
- **Signal 3 / EXPLAIN ANALYZE guidance is technically accurate**: `Physical Input` bytes vs full table size, `Input:` row count, `Filtered:` percentage as the three runtime signals on the TableScan node — this matches the resource (Section 3.4) and the Trino 481 EXPLAIN ANALYZE docs. The `ScanFilterProject` / `Filter` node ABOVE the TableScan call-out is correct (verified via WebFetch of Trino docs and the resource).
- **Correctly distinguishes "rule out other bottlenecks" from "decide to ingest"** — calls out (a) predicate pushdown verification with `EXPLAIN (TYPE DISTRIBUTED)` (free, no execution — good operational note), (b) connection exhaustion as a separate-fix scenario, (c) Trino Web UI CPU vs Blocked time as a way to localize the bottleneck. Each of these maps to a real diagnostic surface.
- **"No native JDBC connection pooling in OSS Trino 467"** claim verified accurate. WebFetch of Trino 481 PostgreSQL connector docs shows no `connection-pool.enabled` property; that property exists in Starburst Enterprise but NOT in OSS Trino. The PgBouncer + `prepareThreshold=0` workaround is the correct production recommendation and matches the resource Section 8.2A.
- **Freshness-as-hinge framing is correct** — federation wins on real-time, Iceberg wins on speed + load isolation. The CDC / micro-batch / nightly cadence ladder is accurately ordered by latency and operational cost.
- **Iceberg partition spec syntax `(day(created_at), bucket(tenant_id, N))`** is valid Iceberg transform syntax and matches the partitioning resource.
- **Migration checklist is concrete and runnable** — 1-week event-listener capture, side-by-side row-count comparison, keep federation as rollback for 1–2 weeks. These are real production-cutover steps.
- **The closing recommendation matches the question's specifics** — 50 queries/day against a users lookup table with no real-time requirement → ingest. Doesn't hedge.

## What the answer missed or got wrong

- **The "20% query volume" threshold (Signal 4) is invented and presented as a hard rule.** This is not in the resource and not a standard heuristic anywhere I could verify. It's directionally reasonable (high-volume access pattern argues for ingestion) but stating "20%+" as a specific cutoff implies a precision that doesn't exist. Should be reframed as "if federation has become the dominant access pattern, not an edge case" without the made-up percentage.
- **The `iceberg.analytics.query_audit_log` SQL example references a table that may not exist in this environment.** The engineer needs to be told this is illustrative and they should substitute their actual event-listener sink — not copy-paste it as-is.
- **Latency SLO numbers (>2s federated vs <500ms Iceberg) are presented without caveat.** Real-world federation latency depends heavily on Postgres replica health, query shape, and pushdown success. The "<500ms with Iceberg" claim assumes a well-partitioned table; without that caveat, the engineer may set the wrong expectation.
- **Doesn't mention the hybrid pattern's operational cost in detail.** The last paragraph mentions it briefly ("Iceberg for history + federated Postgres for the last hour") but doesn't explain that this requires a UNION view, snapshot boundary management, and double the test surface — which is exactly the "ingestion complexity" the engineer was trying to avoid.
- **Missing: dynamic filtering (DF) as a federation-tuning lever.** Before deciding to ingest, the engineer could check whether DF is firing on the federated join (the resource Section 3 mentions DF verification with EXPLAIN ANALYZE). For a users-table lookup in a cross-catalog join, DF could materially change the federation cost equation.
- **Doesn't mention metadata caching** (`metadata.cache-ttl`, `metadata.schemas.cache-ttl`) on the PostgreSQL connector as a cheap tuning step that could reduce Postgres load before ingesting. This is a real "rule out other bottlenecks" lever the answer skipped.

## WebSearch verification notes

- **Trino docs confirm**: OSS Trino PostgreSQL connector (latest, 481) has no `connection-pool.enabled` property. The connection-pool feature appears only in Starburst Enterprise. The answer's "no native JDBC connection pooling in OSS Trino 467" claim is accurate.
- **GitHub issue trinodb/trino#15888** (referenced in the resource) remains the canonical request — still not implemented in OSS as of Trino 481.
- **EXPLAIN ANALYZE field semantics verified**: `Physical Input` reflects bytes read from source before filtering; absence of `ScanFilterProject` above `TableScan` indicates predicate pushdown succeeded; presence of `Filter` or `ScanFilterProject` above `TableScan` with the WHERE clause inside indicates pushdown failed. The answer's interpretation matches the Trino 481 EXPLAIN ANALYZE docs.
- **Iceberg `day()` and `bucket()` transforms** are valid Iceberg partition spec syntax (verified against Iceberg docs).

## Recommendation for teacher

This answer is strong and above the 4.5 threshold for the topic. Two small resource improvements would close the remaining gaps:

1. **Add a "when to stop federating" decision matrix to `22-trino-federation-postgresql.md`** — codify the 5 signals here (Postgres replica CPU, latency SLO breach, full-scan EXPLAIN ANALYZE evidence, freshness loosening, dominant access pattern) WITHOUT inventing a specific percentage threshold for the volume signal. The current resource has the diagnostic mechanics scattered across sections; consolidating them into a single "should I ingest?" checklist would let the responder cite a single section.
2. **Add a "cheap tuning to try first" subsection** before the ingest decision: metadata caching TTL, dynamic filtering verification, predicate-shape fixes (CAST traps, function-on-column). The answer correctly mentions some of these but a dedicated checklist would help the responder structure future answers.
3. **Add an explicit hybrid-pattern caveat**: a UNION view of Iceberg history + Postgres recent rows doubles your test surface and adds snapshot-boundary bugs — only worth it when ingestion truly cannot meet freshness SLO.

Topic update: Trino federation/cross-source — prior avg 4.449 across 112 questions. New avg: (4.449 * 112 + 4.80) / 113 = **4.452 across 113 questions**. Gap to 4.5 threshold: 0.048. Still NEEDS WORK by a hair — one more strong answer (4.7+) would push it over the threshold.
