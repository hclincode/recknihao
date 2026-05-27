# Iter250 Q2 Score

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **5.0** |

**Topic**: Trino federation / cross-source connectors
**Pass/Fail**: PASS (threshold 4.5)

## Strengths
- Correctly identifies the root cause: PostgreSQL side is missing the statistics Trino's CBO needs. Verified against the Trino PostgreSQL connector docs (https://trino.io/docs/current/connector/postgresql.html), which state plainly: "To collect statistics for a table, execute the following statement in PostgreSQL. `ANALYZE table_schema.table_name;`" The answer correctly tells the engineer that `ANALYZE app_pg.public.customer_accounts` in Trino will fail.
- Iceberg ANALYZE / Puffin claim is accurate. Trino's Iceberg connector writes NDV statistics into Puffin sidecar files using a Theta Sketch from Apache DataSketches — confirmed against the Puffin spec (https://iceberg.apache.org/puffin-spec/) and the iceberg connector page (https://trino.io/docs/current/connector/iceberg.html).
- `SHOW STATS FOR catalog.schema.table` claim is correct for both Iceberg and PostgreSQL catalogs (https://trino.io/docs/current/sql/show-stats.html). Mentioning that `distinct_values_count` will be NULL if stats are missing is exactly the right diagnostic signal.
- `Join[BROADCAST]` vs `Join[PARTITIONED]` EXPLAIN labels are real and correctly described. CBO docs (https://trino.io/docs/current/optimizer/cost-based-optimizations.html) confirm that without stats Trino defaults to hash-distributed (PARTITIONED) joins, exactly matching the answer's explanation of why the engineer is seeing the wrong plan.
- Build/probe rule (smaller table = build side, hashed into memory; larger table streamed as probe) is correct and clearly explained for a beginner.
- Dynamic filtering flow from build side to probe side is correctly described, with `dynamicFilters` annotation on the Iceberg scan as the verification signal — accurate per Trino dynamic-filtering docs (https://trino.io/docs/current/admin/dynamic-filtering.html).
- `CALL app_pg.system.flush_metadata_cache()` syntax is valid and properly qualified by catalog. Correctly noted that this is only needed if `metadata.cache-ttl > 0`.
- Step-by-step diagnostic flow (Postgres ANALYZE → verify pg_stats → flush cache if needed → SHOW STATS → EXPLAIN) is exactly what an oncall engineer needs.
- Fits the on-prem k8s Trino 467 + Iceberg + MinIO + Postgres stack perfectly. Mentions Puffin sidecar files landing "next to the table metadata in MinIO" — environment-aware.
- Includes realistic maintenance cadence guidance (after major ingests, weekly routine, autovacuum note).
- Closes with a quantitative payoff estimate ("2x–10x speedup") that helps justify the work.

## Gaps / Errors
- Minor: the answer says "Postgres replica" twice in step 1 and 5 ("on the Postgres read replica"). The engineer's question doesn't specify a replica vs primary; running ANALYZE must happen on the same Postgres instance Trino reads from. If Trino reads a replica, ANALYZE on the primary won't help (statistics in `pg_statistic` need to be present on the replica being queried — typically they replicate via physical replication, but logical replicas would need separate ANALYZE). This nuance isn't called out but is a minor edge case, not a factual error.
- Minor: the answer doesn't mention the optimizer session property `join_distribution_type` or `join_reordering_strategy` as a quick check / temporary override. Not required for completeness, but useful for diagnosis when stats arrive but the plan still looks wrong.
- Minor: doesn't explicitly mention `EXPLAIN ANALYZE` (vs the logical EXPLAIN shown) as a way to see actual row counts vs estimates after the fact. The chosen `EXPLAIN (TYPE LOGICAL)` is appropriate for the question, so this is just an enhancement, not a gap.

Overall this is a textbook-quality answer: every technical claim verified against trino.io docs, complete diagnostic workflow, environment-appropriate, and explained at a level a SaaS engineer with no OLAP background can follow.
