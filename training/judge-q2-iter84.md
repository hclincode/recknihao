# Judge Score — Iter 84 Q2

## Score: 4.75 / 5.0
| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 4 |

## Points covered
Iceberg partition design for SaaS — partition evolution sub-topic:
- Live `ALTER TABLE ... SET PROPERTIES partitioning = ARRAY[...]` syntax shown with correct Trino DDL.
- Explicitly states the change is metadata-only and "future writes only" — no eager rewrite of historical files.
- Explains "split table" state with both partition specs coexisting after ALTER.
- Mixed-spec query semantics: Trino reads files under both specs and returns correct results; new files prune by tenant_id, old files do not.
- `rewrite_data_files` as the migration path to physically reorganize historical data into the new spec.
- Production-stack awareness: Spark procedure (not Trino OPTIMIZE) selected; runs under Spark via spark-submit/Airflow.
- Rollback via snapshot revert.
- Timing/operational guidance for the rewrite window.
- Coordinated maintenance sequence with `expire_snapshots`.
- The "gotcha" — scan size won't drop after ALTER alone — explicitly called out as the most common engineer surprise.
- Summary checklist with five concrete steps the engineer can execute in order.

## Accuracy notes
Verified via WebSearch against trino.io/docs/current/connector/iceberg.html, iceberg.apache.org/docs/latest/evolution/, iceberg.apache.org/docs/latest/spark-procedures/, and trinodb/trino issue tracker:

- `ALTER TABLE ... SET PROPERTIES partitioning = ARRAY['day(occurred_at)', 'tenant_id']` is the documented Trino DDL. The earlier `ALTER TABLE ... SET PARTITIONING` form does NOT exist for Iceberg in Trino. Answer's syntax is correct.
- "Old files are not rewritten, new spec applies to future writes only" — confirmed: partition evolution is a metadata-only operation per Iceberg evolution docs. No eager rewrite.
- Mixed partition spec read correctness — confirmed: Iceberg's hidden-partitioning design translates predicates per-spec so queries return correct results across files written under multiple specs. The answer's "slower but correct" claim is exactly right.
- `rewrite_data_files` reorganizing under the new spec — confirmed: the Spark procedure writes outputs under the table's current partition spec, so post-evolution invocation physically lands historical data into the new layout. The 256 MB target file size and `min-input-files=1` options are valid.
- Production-fit: Trino `ALTER TABLE EXECUTE optimize` has a known limitation that newly-added partition columns cannot be used as predicates (trinodb/trino #25279), which validates the answer's "Spark SQL only" call-out. The answer doesn't cite this specific reason but lands on the correct tool choice.

## Issues / gaps
Minor (Completeness deduction from 5 to 4):

1. **Bucket transform consideration omitted**: The user said "add `tenant_id` to the partition scheme." For high-tenant-count tables this can cause per-file metadata explosion; a brief "if you have hundreds+ tenants per day, consider `bucket(tenant_id, 32)` instead of raw `tenant_id`" would have been useful context that this topic has covered before (Iter 16 Q2, Iter 68 Q2). The answer takes the user's intent at face value, which is defensible but a small completeness gap.
2. **Monitoring rewrite progress unmentioned**: `SELECT spec_id, COUNT(*) FROM <table>.files GROUP BY spec_id` is the canonical way to verify how many files remain on the old spec during/after a rewrite. Same omission was flagged in Iter 73 Q1 — repeated gap on this topic.
3. **Trino OPTIMIZE limitation not named**: Answer says "Spark SQL only" but doesn't explain *why* Trino is unsuitable here. The real reason is trinodb/trino #25279 — Trino's OPTIMIZE cannot use newly-added partition columns as predicates. A one-line citation would strengthen the recommendation.
4. **"Doubling storage" slight imprecision**: Only one snapshot's worth is duplicated until `expire_snapshots` runs, not literal 2x of the whole table. Defensible shorthand but technically imprecise.
5. **Catalog-name inconsistency**: `iceberg.analytics.user_events` (Trino) vs `analytics.user_events` (Spark) without explanation — a beginner would ask "why the difference?"

No factual errors. No misleading guidance. All recommendations are production-stack compatible.

## Resource fix needed?
**No — optional polish only.** Topic running average rose from 4.538 (10q) to 4.557 (11q), comfortably above the pass threshold.

Optional polish for the partition-design resource:
- Add a callout for monitoring rewrite progress via `<table>.files` + `spec_id` (carries over from Iter 73 Q1 suggestion).
- Add a one-line note on the Trino OPTIMIZE / partition-evolution limitation (trinodb/trino #25279) to explain why Spark is preferred for these rewrites.
- Add a cross-reference when adding `tenant_id` as a partition column: prompt to evaluate `bucket(tenant_id, N)` for high-cardinality tenant counts.
