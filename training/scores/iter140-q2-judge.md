# Iter140 Q2 — Judge Evaluation

**Question topic**: Partitioning strategy for skewed multi-tenant events table (80 tenants, top 5 = 60% volume).

## Score Summary

| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 / 5 |
| Beginner clarity | 4.5 / 5 |
| Practical applicability | 5.0 / 5 |
| Completeness | 5.0 / 5 |
| **Overall** | **4.75 / 5** |

**Verdict: PASS** (>= 4.0)

---

## What Was Verified Correct

1. **Iceberg manifests store column-level lower/upper bounds for every column** — VERIFIED.
   Source: https://iceberg.apache.org/spec/ — "Manifest files include a tuple of partition data and column-level stats for each data file. Column-level value counts, null counts, lower bounds, and upper bounds are used to eliminate files that cannot match the query predicate." This is the central claim of the answer and is fully correct.

2. **File-level min/max pruning works on non-partition columns when data is physically clustered** — VERIFIED.
   Source: https://iceberg.apache.org/docs/latest/performance/ — "By using upper and lower bounds to filter data files at planning time, Iceberg uses clustered data to eliminate splits without running tasks." The answer's emphasis that sort-clustering by `tenant_id` enables effective file pruning even when `tenant_id` is not in the partition spec is accurate.

3. **`rewrite_data_files` with `strategy => 'sort'` and `sort_order => '...'` is a valid Iceberg Spark procedure** — VERIFIED.
   Source: https://iceberg.apache.org/docs/1.5.1/spark-procedures/ — Exact call form documented: `CALL catalog_name.system.rewrite_data_files(table => 'db.sample', strategy => 'sort', sort_order => 'id DESC NULLS LAST,name ASC NULLS FIRST')`. The `options => map('target-file-size-bytes', ..., 'min-input-files', ...)` form is also valid. The `rewrite-all` option in the partition-evolution example is real.

4. **`$files` metadata table exposes `lower_bounds` and `upper_bounds` map columns** — VERIFIED.
   Source: https://trino.io/docs/current/connector/iceberg.html — "$files" table includes columns `lower_bounds` and `upper_bounds`, each a "map from column id to lower/upper bound." The Trino syntax `lower_bounds['tenant_id']` in the answer is correct (Trino accepts map subscript on these columns).

5. **Trino `ALTER TABLE ... SET PROPERTIES partitioning = ARRAY[...]` for partition evolution** — VERIFIED.
   Source: Trino release 382 (May 2022) added this; https://trino.io/docs/current/connector/iceberg.html — "Partitioning can also be changed and the connector can still query data created before the partitioning change." Syntax used in the answer is current and valid for Trino 467.

6. **Old files stay on the old spec; new files use the new spec; queries prune transparently** — VERIFIED via Iceberg spec partition-specs array.

7. **Bucket partitioning hashes tenant IDs to buckets** — accurate description of the `bucket(col, N)` transform.

8. **Partition skew, small-file accumulation, partition count explosion** — all three pathologies are accurately described and quantified (e.g., 80×365=29,200 partitions/year).

9. **Recommendation order (Phase 1 → Phase 3) and the "isolate whales into dedicated tables" pattern** — well-grounded SaaS multi-tenant practice that fits the on-prem Trino+Iceberg+MinIO stack described in `prod_info.md`.

---

## Errors / Gaps

### MEDIUM

1. **Bucket partitioning "prevents metadata-only COUNT(*) GROUP BY"** — overstated.
   The claim "billing queries (`SELECT tenant_id, COUNT(*) GROUP BY tenant_id`) can no longer be answered from metadata alone" is partly true but misleading. With raw identity-partitioning by `tenant_id`, Trino can use the partition-spec values from manifest metadata. With `bucket(tenant_id, N)`, the partition value is the bucket number, not the tenant id, so a GROUP BY on `tenant_id` does require reading data files to get distinct tenant values — but Trino can still satisfy `COUNT(*)` (without GROUP BY) from `record_count` in manifests in many cases, even with bucket partitioning. The answer conflates the two. A precise statement would be: "GROUP BY tenant_id cannot be answered from partition metadata when bucket() is used, because the partition value is a hash bucket, not the tenant id."

2. **`CALL iceberg.system.rewrite_data_files(...)` in the partition-evolution example** is not labeled as Spark-only.
   The earlier sort-compaction snippet is correctly framed as Spark (Python). The second snippet under "Partition Evolution" reuses the same call without re-labeling, which a beginner might paste into Trino. In the prod environment (`Trino 467` for queries, `Spark with Iceberg 1.5.2` for ingestion), this is an ongoing risk. The answer should explicitly say "run from Spark" again, or note "Trino equivalent: `ALTER TABLE ... EXECUTE optimize`" (which does not support sort_order parameters — it relies on table-level `sorted_by` table property).

3. **`rewrite-all` is shown without explaining the operational cost.**
   Rewriting all historical data on a large multi-tenant events table can be enormously expensive (rewrites every byte). The answer presents it as a casual follow-up to partition evolution without warning about cost, downtime risk, or the alternative of letting new data accumulate under the new spec and only rewriting recent/hot partitions. There is also a known issue (apache/iceberg #14667) where `rewrite-all=true` combined with a `where` predicate can produce duplicate rows — worth a brief caution.

### LOW

4. **"Iceberg has two independent pruning mechanisms"** — slightly oversimplified.
   There are actually three commonly cited layers (partition pruning, file-level min/max pruning via manifest stats, and Parquet row-group pruning inside files). Saying "two" undercounts. Not a blocking issue — the answer is focused on the file-level layer for clarity.

5. **The Trino `EXPLAIN ANALYZE` output annotation "Files: N out of M"** — the actual label in Trino EXPLAIN ANALYZE output is more like `input rows / input files` in operator stats or `Input: X rows (Y bytes)` rather than the exact "Files: N out of M" string. Close enough conceptually that a beginner can find the relevant numbers, but the exact label is imprecise.

6. **Sort key choice** — sorting on `(tenant_id, occurred_at)` is good, but the answer doesn't briefly mention that for very high-cardinality secondary access patterns, z-order could be considered (the rewrite procedure also supports `sort_order` with zorder strategy). Minor — out of scope for this question.

---

## Resource Fix Recommendations

These are minor/incremental — the topic is already PASSED at 4.577 across 14 questions. No urgent rewrites needed. Suggested touch-ups for whichever resource covers partitioning + compaction:

- Add a short callout to the rewrite_data_files reference: "**Engine:** This `CALL` runs from Spark only. From Trino, use `ALTER TABLE ... EXECUTE optimize`, but note Trino's optimize honors the table's `sorted_by` property rather than an inline `sort_order` argument."
- Add a one-line caution next to `rewrite-all` examples: "Rewrites every data file — can be very expensive on large tables; prefer scoped rewrites (`where` filter or partition-bounded) when possible. Known issue: combining `rewrite-all=true` with a `where` predicate can produce duplicate rows (apache/iceberg #14667)."
- Clarify the metadata-only optimization caveat: differentiate "COUNT(*)" (often answerable from manifest record_count even with bucket partitioning) from "GROUP BY identity-partition-column" (only answerable from metadata when the GROUP BY column is an identity partition value, not a bucket hash).

---

## Notes for state.json / rubric

- Topic touched: **Iceberg partition design for SaaS: strategies, small-files, compaction** (already PASSED, avg 4.577, 14 questions).
- This is a strong 2nd/3rd angle question on the same topic with thorough, environment-fit answer. No status change.
- Also touches: **Query performance basics** (PASSED, 4.594) and **Iceberg table maintenance** (PASSED, 4.602) via the compaction discussion.
