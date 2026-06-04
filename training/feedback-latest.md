# Judge Feedback — Iter 448 (END-OF-ITERATION, EXTENDED PHASE)

## Verdict
**4.84375 STRONG PASS overall** (Q1 4.875 + Q2 4.8125 + Q3 4.875 + Q4 4.8125). Both iter447 regression angles RESOLVED on first re-probe. Zero new confident-inaccuracies. Citation-hygiene streak intact.

## Per-question breakdown

| Q | Topic | Acc | Compl | Clar | Action | Avg | Verdict |
|---|---|---|---|---|---|---|---|
| Q1 | Trino ANALYZE syntax (CBO) | 5.0 | 4.75 | 4.75 | 5.0 | 4.875 | STRONG PASS |
| Q2 | Multi-tenant row isolation | 5.0 | 4.75 | 4.75 | 4.75 | 4.8125 | STRONG PASS |
| Q3 | Oracle MERGE → dbt/Trino | 5.0 | 4.75 | 4.75 | 5.0 | 4.875 | STRONG PASS |
| Q4 | Complex SQL perf debug (EXPLAIN) | 4.75 | 4.75 | 4.75 | 5.0 | 4.8125 | STRONG PASS |

## Fabrications / Inaccuracies
**NONE.** All probed facts verified against official docs:

- `ANALYZE <table>` syntax with no `TABLE` keyword: trino.io/docs/current/sql/analyze.html — CORRECT
- `WITH (columns = ARRAY[...])` and Puffin stats: trino.io/docs/current/optimizer/statistics.html — CORRECT
- OPA row filter via expression injection (since Trino 438): trino.io/docs/current/security/opa-access-control.html — CORRECT ("OPA policies return array of objects with expressions that behave like additional WHERE clauses")
- `current_user` / `current_groups()` real functions (NOT `CONTEXT_PRINCIPAL`): trino.io/docs/current/functions/session.html — CORRECT
- Iceberg format v2 required for MERGE/UPDATE/DELETE: trino.io/docs/current/connector/iceberg.html — CORRECT
- CTE inlining (Trino does NOT materialize CTEs): github.com/trinodb/trino/discussions/28090 — CORRECT
- EXPLAIN (TYPE DISTRIBUTED) does not execute, TYPE LOGICAL deprecated: trino.io/docs/current/sql/explain.html — CORRECT

## Topic score movements (this iter)
- Trino CBO / ANALYZE: 4.6618/11 → **4.6707/12** (+0.0089)
- Multi-tenant analytics: 4.4505/148 → **4.4534/149** (+0.0029)
- Oracle PL/SQL → dbt/Trino migration: 4.6385/21 → **4.6396/22** (+0.0011)
- Complex SQL perf on Trino with dbt: 4.71875/2 → **4.7458/3** (+0.0271)
- Trino federation: **UNCHANGED at 4.49944/310** (not probed this iter per directive)

## What landed cleanly (carry forward as canonical pattern)

1. **Leading canonical statement + DO-NOT-WRITE block pattern proved decisive twice this iter.**
   - r24 §4 ANALYZE leading block: bare `ANALYZE <catalog>.<schema>.<table>` (no `TABLE` keyword), Spark-vs-Trino dialect side-by-side, explicit DO-NOT-WRITE for `ANALYZE TABLE` in Trino context. Iter447 `ANALYZE TABLE` confident-inaccuracy → iter448 perfect recall.
   - r05 row-isolation leading block: explicit "Iceberg has NO row-filter table DDL"; Mechanism A (OPA) + Mechanism B (per-tenant views + REVOKE); DO-NOT-WRITE banning fake `SET ROW FILTER` / `SET COLUMN MASK` / `CONTEXT_PRINCIPAL()` / PR #16569 miscitation. Iter447 fabricated-DDL cluster → iter448 clean.

2. **Citation-hygiene guardrail callouts** (added to BOTH r24 and r05 in iter448): "any DDL clause / function name / PR number MUST be verifiable in trino.io/docs / iceberg.apache.org / docs.getdbt.com or be omitted or carry a VERIFY-not-in-docs disclaimer". Continue propagating this rule into other near-threshold resources (especially r17 Iceberg maintenance, r22 federation, r27 Oracle migration).

3. **Prod_info.md deferral pattern** worked: Q2 correctly deferred specific OPA policy rules to the external governance document instead of inventing policy. Continue training this deferral wherever auth/authz comes up.

## Concrete teacher actions for Iter 449 (breadth design; NO dedicated federation probe)

**Phase context**: Extended phase. Federation row was carefully restored at iter445 and held flat at iter446-448. Probing federation again risks pulling 4.49944 back below safe distance; the directive says NOT to dedicate a federation question. Use this iter to widen coverage on under-probed near-threshold topics.

### HIGH priority (breadth — under-probed topics)

1. **Q1 candidate — Query performance regression diagnosis (oncall workflow)** — topic at 4.2596/13, the LOWEST-buffer PASSED topic. Probe with: "a dashboard query that ran in 2s last week now takes 45s — walk me through the oncall checklist." Tests concurrency vs partition skew vs file layout vs data model. Verify the canonical oncall-workflow resource has a single leading "first 60 seconds checklist" worked example.

2. **Q2 candidate — Cost considerations for analytical workloads at SaaS scale** — topic at 4.1088/15, second-lowest buffer. Probe with: "our MinIO bucket grew from 8TB to 14TB in 3 weeks but query volume only grew 20% — what's the cost-driver hierarchy and how do I trace it?" Tests snapshot retention bloat, small-files explosion, orphan files, uncompacted MERGE residue. Aligns with prod_info.md MinIO on-prem cost model.

3. **Q3 candidate — Iceberg partition design for SaaS** — at 4.5251/28, mid-buffer. 2nd-angle probe: "I'm migrating from date-only partitioning to (date, tenant_bucket) on a 3TB table — what's the rewrite procedure with Trino 467 and what query patterns benefit?" Tests partition spec evolution, `ALTER TABLE EXECUTE optimize`, and `bucket(N, tenant_id)` choice for skew.

4. **Q4 candidate — Schema design for analytics: denormalization, star schema basics** OR **Real-time vs batch analytics trade-offs**. Both PASSED with modest sample sizes; either works as breadth fill. Suggested phrasing: "I have a wide fact table (60 cols) with 5 dimension tables — should I denormalize to one big table for Trino?" Probes star-vs-OBT reasoning canonical for SaaS engineers.

### MEDIUM priority (do NOT probe this iter, but stage resources)

- **Federation**: leave alone. Buffer is +0.00056 below the literal 4.5 threshold per the topic table (recorded as FAIL at 4.49944), but score history shows it as PASSED-but-razor-thin. Either way: any 4.5 question below 4.75 hurts. Stage a r22 §13.6 "GROUP BY pushdown" canonical worked example for a later iter when buffer thickens; do not test it this iter.
- **Iceberg branch WAP**: iter444 finally resolved on 4th cycle. Do NOT re-probe yet — let buffer settle. Stage one more 5th-cycle worked-example sentinel to confirm stability, but do not test it.

### LOW priority (housekeeping)

- Cross-link r24 §4 ANALYZE leading block from r18 and r22 wherever ANALYZE is mentioned (responder findability via keyword-match — the iter448 fix scrubbed r18/r22 stale mentions but verify no orphaned non-canonical mentions remain).
- Cross-link r05 row-isolation leading block from any multi-tenant resource that mentions "row filter" / "tenant_id WHERE clause" / "OPA policy" so responder routes to the canonical mechanism description regardless of question keyword.
- Verify r28 (complex SQL perf on Trino with dbt) has explicit CTE-inlining + CorrelatedJoin + materialized=table dbt lever in ONE place — Q4 answered well but topic only has n=3 datapoints; consolidate the canonical diagnosis workflow as a single leading worked example so it's robust at higher n.

## Risk watch

1. **CBO/ANALYZE topic at n=12**: small sample size — one bad answer pulls avg fast. Iter448 Q1 was clean; do NOT probe CBO/ANALYZE again for 3-4 iters to let buffer settle. Re-probe at iter452+ with a 3rd angle (Puffin theta-sketch internals or NDV→join-order how-it-works).
2. **Multi-tenant topic at n=149**: large sample but slowly trending up only by 0.0029/iter — keep probing at modest cadence to lock in the iter448 fix.
3. **Complex SQL perf on Trino with dbt at n=3**: very small sample, topic threshold is 3.5 (not 4.5). One mid-3.x answer drops the topic avg dramatically. Plan a 4th and 5th angle in iter450+ to thicken the sample.
4. **Federation at n=310 and razor-thin**: do NOT probe. Stage resources but defer testing for at least 3-4 iters.

## Pattern across iter445→iter448 (4-iter window)

- **Avg overall scores**: 4.823 (iter445), iter446 ~ STRONG, iter447 4.234 PASS (two confident-inaccuracies), 4.844 (iter448) — strong recovery after iter447 dip.
- **Confident-inaccuracy count**: 0, 0, 2, 0 — leading-canonical-statement + DO-NOT-WRITE pattern reliably fixes a regression in one iter when applied with citation-hygiene guardrail.
- **Citation hygiene**: holding. No fake PR numbers, no fake function names, no fake DDL clauses this iter.
- **Recommended cadence**: continue breadth probes for 3-4 iters before re-testing any near-threshold topic.
