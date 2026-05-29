# Judge Feedback — Iter 402

**Date**: 2026-05-30
**Phase**: extended
**Verdict**: **FAIL** (iteration average 3.875 < 4.0 PASS threshold)

---

## Score Summary

| Question | TA | BC | PA | Comp | Avg | Verdict |
|---|---|---|---|---|---|---|
| Q1 — Iceberg DROP COLUMN | 5 | 4.5 | 4.5 | 4.5 | **4.625** | PASS |
| Q2 — Trino IN subquery vs JOIN | 2.5 | 4 | 3.5 | 2.5 | **3.125** | FAIL |
| **Iteration** | | | | | **3.875** | **FAIL** |

---

## Q1 — Iceberg DROP COLUMN (4.625 PASS)

**What the responder said**: DROP COLUMN is metadata-only (instant); existing Parquet files keep the column bytes until rewrite_data_files; new writes exclude the column; storage not reclaimed until explicit compaction; audit consumers before dropping.

**Strengths**:
- Field-ID-based metadata-only DROP is correct (Iceberg's schema evolution model).
- "Existing Parquet keeps the bytes" is the right mental model — Parquet files are immutable; only rewrite_data_files (or eventual expire_snapshots after rewrite) reclaims storage.
- "New writes exclude the column" is correct — writers consult the current schema, so subsequent Parquet files won't carry the dropped column.
- Consumer-audit reminder is the missing operational step in most beginner answers. Downstream `SELECT col` will break; column-name reuse can collide with a different field ID.

**Gaps (minor)**:
- No mention of Trino 467 syntax: `ALTER TABLE ... DROP COLUMN col_name` + `ALTER TABLE ... EXECUTE optimize` + `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')` as the on-stack reclaim path.
- No mention of Spark-side `CALL system.rewrite_data_files` equivalent.
- No partition-column DROP edge case (cannot drop a partition column without rewriting the spec).
- No v2 equality-delete-files interaction (delete files referencing the dropped column).

---

## Q2 — Trino IN subquery vs JOIN (3.125 FAIL)

**What the responder said**: Honest punt — resources don't cover correlated subquery optimization; gave practical EXPLAIN-based comparison advice; recommended running ANALYZE for CBO stats.

**Critical technical gap (WebSearch-verified)**:
Trino's optimizer DOES automatically convert uncorrelated IN subqueries to SemiJoin operators. Verified against Trino docs:
- "Semi-Join (IN) Decorrelation" is a documented optimizer rule.
- The SemiJoin operator uses precomputed hash (`optimize-hash-generation` enabled by default).
- For correlated subqueries, Trino runs a "Decorrelate Subqueries" optimization rule.

**What a correct answer looks like**:
1. Trino auto-converts uncorrelated IN→SemiJoin (verify with EXPLAIN — look for `SemiJoinNode`).
2. For correlated subqueries, Trino decorrelates when possible.
3. Manual IN→JOIN rewrite usually doesn't help — JOIN doesn't dedupe like SemiJoin does, so naive rewrite introduces duplicates.
4. If EXPLAIN shows `CorrelatedJoin` (decorrelation failed), THAT is when manual rewrite warrants investigation.
5. NOT IN with NULL gotcha — usually want NOT EXISTS instead.

**Why the punt was wrong here**:
The "honest punt" pattern is correct when the upstream tool's behavior is genuinely undocumented or environment-specific. But Trino's IN/SemiJoin behavior is explicitly documented in Trino docs and is well-known optimizer behavior. The punt implies the engineer must manually choose — the truth is Trino's planner usually picks for them, and the engineer's job is to verify via EXPLAIN, not to manually rewrite.

The EXPLAIN + ANALYZE advice is correct but generic. It doesn't tell the engineer what to LOOK FOR in EXPLAIN output (SemiJoinNode for uncorrelated, CorrelatedJoin for failed decorrelation).

---

## Teacher Actions for iter403

### HIGH priority

1. **Trino subquery optimization resource** covering:
   - Trino auto-converts uncorrelated IN→SemiJoin (cite `optimize-hash-generation` default-enabled).
   - Trino decorrelates correlated subqueries via "Decorrelate Subqueries" rule.
   - EXPLAIN signatures: `SemiJoinNode` (uncorrelated, optimal) vs `CorrelatedJoin` (decorrelation failed, manual rewrite warranted).
   - Manual IN→JOIN rewrite usually doesn't help and can introduce duplicates (JOIN doesn't dedupe; SemiJoin does).
   - NOT IN with NULL gotcha — rewrite to NOT EXISTS.

2. **Iceberg DROP COLUMN resource** covering:
   - Metadata-only on commit; field-ID-based schema evolution.
   - Parquet bytes retained until rewrite_data_files.
   - Trino 467 syntax: `ALTER TABLE ... DROP COLUMN` + `ALTER TABLE ... EXECUTE optimize` + `ALTER TABLE ... EXECUTE expire_snapshots`.
   - Spark equivalent: `CALL system.rewrite_data_files` + snapshot expiry.
   - Partition column DROP edge case.
   - v2 equality delete files referencing dropped column.
   - Consumer-audit checklist (downstream `SELECT col` will fail; column-name reuse collides with new field ID).

### LOW priority (carry-forward from iter401)

3. dbt-trino post_hook literal snippet: `post_hooks=["ALTER TABLE {{ this }} EXECUTE optimize", "ALTER TABLE {{ this }} EXECUTE expire_snapshots(retention_threshold => '7d')"]`.
4. EXPLAIN output text snippets for predicate pushdown (literal `TableScan[table=..., constraint=...]` vs `ScanFilterProject[...]`).
5. `pushdownFilters` / `aggregation-pushdown.enabled` connector config check + unpushable predicate warnings (LIKE leading-wildcard, function-on-column).

---

## Judge Probe Targets for iter403

1. **2nd-angle Trino subquery**: "my EXPLAIN shows CorrelatedJoin not SemiJoin — what does that mean and how do I fix it" — probes failed-decorrelation diagnosis.
2. **2nd-angle Iceberg DROP COLUMN**: "I dropped a column 3 weeks ago but my MinIO usage didn't drop — what's wrong" — probes rewrite_data_files + expire_snapshots reclaim path.
3. **NOT IN NULL gotcha**: "my NOT IN query returns zero rows but I know there's matching data" — probes NULL semantics in NOT IN.
4. **Carry-forward backlog**: dbt-trino merge duplicates angle, predicate-pushdown JDBC layer rewrite angle, CoW vs MoR write.merge.mode angle, write.isolation-level 2nd-angle, SHOW SESSION/catalog-prefix 2nd-angle, HMS->Nessie no-downtime, SPILL_FAILED at 60GB cap, MERGE INTO rollback, OPA-override timeout, schema registry compat, EXPLAIN TYPE IO + VALIDATE, result caching 2nd-angle, Iceberg branches fast_forward 2nd-angle, JWT+OPA concurrency, partition spec migration + rewrite_data_files, Iceberg tagging 3rd-angle, fs.cache 3rd-angle JMX, bucket(tenant_id) high-cardinality 2nd-angle, PERCENT_RANK/NTILE 3rd-angle, RANGE INTERVAL gap-day semantics.

---

## Pattern Observation

**iter392-402** (4.75/4.125/3.9375F/4.625/4.75/3.125F/4.3125/4.375/4.34375/4.09375/4.0625/3.8125F/4.59375P/**3.875F**): iter401 PASS broke after one cycle. Post-fail recovery from iter400→iter401 did NOT durably stabilize the responder.

**Failure mode this iteration**: the "honest punt" pattern. The responder is correctly trained not to fabricate, but is over-applying the punt to questions where the upstream tool's behavior IS documented and SHOULD be in resources. This is a resource-coverage gap, not a responder hallucination problem — the teacher needs to add Trino subquery optimization content so the responder has something to ground on next time.

Sources:
- [Trino Optimizer properties documentation](https://trino.io/docs/current/admin/properties-optimizer.html)
- [Trino blog — Using Precomputed Hash in SemiJoin Operations](https://trino.io/blog/2019/05/30/semijoin-precomputed-hasd.html)
- [Trino Cost-based optimizations](https://trino.io/docs/current/optimizer/cost-based-optimizations.html)
- [Trino episodes — Cost Based Optimizer, Decorrelate subqueries](https://trino.io/episodes/7.html)
