# Iter272 Q2 Score

**Score**: 4.75 / 5.0
**Pass/Fail**: PASS

## Dimension scores
- Technical accuracy: 4.5/5
- Beginner clarity: 5/5
- Practical applicability: 5/5
- Completeness: 4.5/5

## What the answer got right
- Correctly diagnoses the symptom: without DF, Trino effectively reads more of Postgres than expected, and joins fall back to in-memory predicate evaluation.
- Build side → collect values → push runtime predicate to probe side is described correctly. The IN-list framing is accurate and useful for an engineer.
- Iceberg file skipping via per-file min/max stats once the runtime predicate is pushed down is correct.
- Join-type matrix is correct per official docs: INNER and RIGHT OUTER enable DF; LEFT and FULL OUTER do not. (Semi-joins with IN are also supported per docs but omitting them is fine for this question.)
- `iceberg.dynamic-filtering.wait-timeout` is the correct config property name.
- **Default of 1 second is correct** for Trino 467 (verified against trino.io/docs/467 Iceberg connector page) — this was the exact fix called out in iter164 Q2.
- `enable_dynamic_filtering` session property name is correct.
- `DynamicFilter` showing up in the `ScanFilterProject` node of EXPLAIN ANALYZE VERBOSE is the right signal.
- Actionable three-step diagnostic (join type → wait timeout → EXPLAIN ANALYZE) maps directly to the engineer's symptom.
- Bonus: the LEFT OUTER fallback pattern (INNER + UNION ALL with NOT EXISTS) and the call-out that a slow build side can still exceed even a 10s timeout are both production-grade advice.

## Errors or gaps
- The session SQL `SET SESSION iceberg.dynamic_filtering_wait_timeout = '10s'` only works if the catalog is **literally named `iceberg`**. The correct general form is `SET SESSION <catalog_name>.dynamic_filtering_wait_timeout = '10s'`. The answer should note that "iceberg" is the catalog name placeholder, not the connector type. This is the recurring trap flagged in iter164 Q2 feedback.
- The EXPLAIN ANALYZE plan snippet is stylized. Real Trino output is closer to `ScanFilterProject[... dynamicFilters = {"user_id" = #df_370}]` with a separate `Dynamic filters:` section listing the domain. Engineers grepping for the literal `DynamicFilter[column=...]` string may not find it. Minor presentation issue, not a correctness failure.
- Iceberg's primary file-skipping mechanism for DF on partitioned columns is partition pruning + min/max on data files. The answer mentions min/max but does not call out that DF is most effective when the join column correlates with partitioning or sort ordering on the Iceberg side. For a tenant/date-partitioned table joined on `user_id`, DF may help less than the answer implies unless `user_id` correlates with file clustering. This nuance is missing.
- No mention that DF on the PostgreSQL connector itself (filter pushed INTO Postgres) does not happen in the direction the user is asking — DF pushes the lookup values into Iceberg, not the Iceberg filter into Postgres. The user's framing ("make Trino push the filter down so it only fetches the relevant rows from Postgres") is slightly misdirected, and the answer doesn't explicitly correct that mental model. It implicitly answers correctly (the small table is fully scanned because it's the build side, by design) but should say so plainly.
- No mention of broadcast vs partitioned join: DF is most effective for broadcast joins, which is the natural plan for a 5K-row build side. A brief sentence on `join_distribution_type` would round out completeness.
- Production fit: no mention of OPA potentially intercepting the SET SESSION (low risk, but worth a line for this environment).

## WebSearch findings
- trino.io/docs/467/connector/iceberg.html — confirms `iceberg.dynamic-filtering.wait-timeout` default is **1s** in Trino 467. Answer is correct.
- trino.io/docs/current/admin/dynamic-filtering.html — confirms DF supports INNER joins, RIGHT joins, semi-joins with IN; does NOT support LEFT OUTER or FULL OUTER. Matches answer's table.
- Session property catalog-prefix syntax confirmed: `SET SESSION <catalog>.dynamic_filtering_wait_timeout = '10s'`. Answer's literal `iceberg.` works only if catalog is named `iceberg`.
- EXPLAIN ANALYZE VERBOSE shows dynamic filters as `dynamicFilters = {"col" = #df_N}` on ScanFilterProject. Answer's stylized snippet is conceptually right but not literal output.

## Topics updated
Trino federation — prior avg 4.481 across 217 questions (Q1 iter272 score should be applied first by Q1 judge; this Q2 update uses the base figure per the note). New running avg using base: (4.481 × 217 + 4.75) / 218 = (972.377 + 4.75) / 218 = 977.127 / 218 = **4.482 across 218 questions**. Status: NEEDS WORK (4.482 < 4.500 raised threshold). Gap: 0.018 — continuing to inch toward threshold; another ~10 answers at ≥4.75 will cross it. Q1 judge should recompute Q2's prior after applying Q1 score.
