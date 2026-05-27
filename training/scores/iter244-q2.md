# Iter244 Q2 Score

| Dimension | Score |
|---|---|
| Technical accuracy | 3.5 |
| Beginner clarity | 4.5 |
| Practical applicability | 5.0 |
| Completeness | 4.5 |
| **Average** | **4.375** |

**Topic**: Trino federation / cross-source connectors
**Pass/Fail**: FAIL (threshold 4.5; missed by 0.125)

## Strengths
- Excellent decision framework: starts with "measure first" before deciding to copy, with concrete observable signals (replica CPU >70%, query latency vs SLO, query volume share, physicalInputBytes via EXPLAIN ANALYZE VERBOSE).
- Strong scenario-to-verdict table that maps row counts / freshness tolerance / change frequency to the right pattern (federate, copy nightly, incremental, CDC).
- Correctly identifies that the broadcast default is 100MB and that 50M rows of customer data exceed that — the architectural intuition is right even if the directional reasoning is muddled (see Gaps).
- Correctly cites the VARCHAR range predicate pushdown limitation (verified against Trino docs: range predicates on character types are NOT pushed down by default due to collation differences).
- Hybrid pattern (Iceberg historical + Postgres last-hour federated tail with `UNION ALL` view) is a genuinely useful production architecture and well-articulated with the predicate-pushdown rationale on both sides.
- `MERGE INTO` / `overwritePartitions()` vs `append()` idempotency callout is correct and load-bearing for incremental ingest.
- Concrete next-step plan (measure, then nightly incremental, then hybrid view, then document SLO) gives the engineer a clear path.
- Frames freshness SLO as the single number driving the architectural choice — excellent mental model.

## Gaps / Errors
- **Dynamic filtering direction is reversed (CRITICAL technical error).** The answer claims Trino "builds a list of tenant IDs in your event sample, converts that to an IN-list, and pushes it to Postgres." This has the build/probe sides backward. With a 50M dimension and 500M fact table, the CBO will choose the SMALLER table (Postgres customers) as the build side and push the resulting dynamic filter into the EVENT LOG (Iceberg) probe scan — not into Postgres. For DF to be pushed to Postgres, the 500M event log would have to be the build side, which contradicts how CBO sizes broadcast/partitioned joins. This inverts the very mechanism the answer is using to justify federation viability.
- **Misses the domain-compaction-threshold ceiling.** Even if direction were correct, Trino compacts dynamic-filter IN-lists exceeding `domain-compaction-threshold` (default 256) into BETWEEN ranges before pushdown. So no realistic 50M-row scenario will produce a 50M-value IN-list to Postgres — the IN-list gets collapsed to a min/max range, which on VARCHAR join keys also runs into the VARCHAR range-pushdown limitation the answer otherwise cites.
- **"Trino will stream the probe side instead — less efficient" mischaracterizes partitioned-join distribution.** When the build side exceeds `join-max-broadcast-table-size`, Trino switches to PARTITIONED (hash-shuffle) join distribution — both sides get shuffled by hash key. It's not "streaming the probe side"; that phrasing will confuse the reader about what's actually happening.
- **No mention of `enable_large_dynamic_filters`** / `domain_compaction_threshold` session properties as tuning levers for federated-join cases — these are exactly the knobs an engineer in this situation would want to know about (per Trino dynamic-filtering docs).
- **No production-fit framing.** Does not reference the on-prem MinIO + Trino 467 + Spark + HMS stack from `prod_info.md`. Says "Spark JDBC read + Iceberg rewrite every night" — correct tooling but no acknowledgment that this is exactly the prod ingestion path. Also misses that Trino 467 OSS PostgreSQL connector has no native connection pool (a recurring resource gap), which is relevant to "destroy the replica" concerns.
- **`updated_at` watermark guidance is missing the soft-delete/late-arrival caveat.** `WHERE updated_at > last_run_ts` misses deletes (no row to detect) and doesn't address clock skew between Postgres and Spark — should at least flag this.

## Topic update
- Trino federation: prior 4.440 across 161 → new running avg (4.440 × 161 + 4.375) / 162 = (714.84 + 4.375) / 162 = **4.440 across 162 questions**. Status: NEEDS WORK (4.440 < 4.5 raised threshold; this question did not move the topic forward).

## Recommended teacher fixes
- **HIGH (correctness)** — `resources/22-trino-federation-postgresql.md`: add a clear "Which side is the build side?" subsection explaining the CBO rule (smaller table → build side → source of dynamic filter), with the worked example for the canonical SaaS shape (small Postgres dim + large Iceberg fact). Make explicit that DF flows FROM Postgres scan INTO Iceberg scan, not the other way around.
- **HIGH (correctness)** — Same resource: document `domain-compaction-threshold` (default 256) and `enable_large_dynamic_filters` as the two tuning levers, and warn that IN-list pushdown to Postgres collapses to range pushdown above the threshold — which then collides with the VARCHAR range-pushdown limitation for string join keys.
- **MEDIUM (clarity)** — Replace any "stream the probe side" language with the correct PARTITIONED vs BROADCAST distribution explanation triggered by `join-max-broadcast-table-size`.
- **MEDIUM (production fit)** — When recommending Spark JDBC + Iceberg ingest, name the prod stack (Spark + HMS + MinIO via S3 protocol) and reference Iceberg 1.5.2 / Trino 467 compatibility so the reader knows the advice is on-rails for their environment.
