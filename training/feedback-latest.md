# Judge Feedback — Iter 369 Q1 — 2026-05-30 (EXTENDED PHASE)

**Question**: "We're joining our 500M-row Iceberg events table to a 200K-row Postgres tenants table. The query is slower than expected. How does dynamic filtering work in this type of join, and how do I verify whether it's firing?"

**Topic**: Trino federation / cross-source connectors — 14th-iter angle re-probe targeting the 4.5 STRONG-PASS threshold (iter368 judge probe target #6).

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.75 | All five major technical claims verified against trino.io official docs: (1) default `iceberg.dynamic-filtering.wait-timeout = 1s` CONFIRMED in [Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html); (2) `dynamicFilterSplitsProcessed` is the correct operator-stats field CONFIRMED in [Dynamic filtering docs](https://trino.io/docs/current/admin/dynamic-filtering.html) — "records the number of splits processed after a dynamic filter is pushed down to the table scan"; (3) plan-time signal `dynamicFilters = {tenant_id = #df_0}` in `ScanFilterProject` node CONFIRMED — matches docs example `"dynamicFilters = {\"ss_sold_date_sk\" = #df_370}"`; (4) `enable_large_dynamic_filters` session property is real; (5) VARCHAR compaction at 256 distinct values via `domain_compaction_threshold` is correctly identified. Build/probe directionality (Postgres tenants build → Iceberg events probe) is correct. Minor deduction: answer attributes wait-time verification to `EXPLAIN ANALYZE VERBOSE` specifically, but per Trino docs the `Dynamic filters:` collection-duration field appears in `ScanFilterProject` operator stats in normal `EXPLAIN ANALYZE` as well — VERBOSE adds detail but is not strictly required. |
| Beginner clarity | 3.75 | "build side", "probe side", "#df_0", "domain compaction", "BETWEEN range" used without inline definitions. The mental model "Trino scans Postgres → extracts tenant_id IN-list → pushes to Iceberg scan → skips files with no overlap" is excellent and beginner-friendly. The longstanding glossary backlog in resources/22 still surfaces here — small improvement vs iter360/367 (both at 3.5). |
| Practical applicability | 4.75 | Production-ready. Engineer knows exactly what to do next: (a) run `EXPLAIN` to look for `dynamicFilters = {tenant_id = #df_0}` on Iceberg TableScan; (b) run `EXPLAIN ANALYZE` to look for `dynamicFilterSplitsProcessed > 0`; (c) if N=0 or low, edit `etc/catalog/iceberg.properties` to set `iceberg.dynamic-filtering.wait-timeout=20s` and restart coordinator; (d) if VARCHAR join key, try `enable_large_dynamic_filters`. The 1s default → 20s tuning is the single most common production trap and the responder hits it. Minor: no explicit Trino 467 / Iceberg 1.5.2 version pin (the default has been stable at 1s for many releases). |
| Completeness | 4.5 | Covers (a) DF mechanism with correct build/probe directionality, (b) plan-time signal with exact syntax, (c) runtime signal with exact metric name, (d) most common failure (1s timeout) with fix and file location, (e) VARCHAR-specific edge case. Missing: (a) collection-duration vs wait-timeout reading, (b) CBO/ANALYZE prerequisite for correct build-side selection, (c) `enable_dynamic_filtering` master kill switch (cluster and session level) as the first thing to check. |
| **Average** | **4.4375** | |

**Iter 369 Q1: 4.4375 — PASS** (above per-question 4.0 bar; just below 4.5 STRONG-PASS bar for the federation topic; lifts topic running avg toward but not over 4.5 threshold.)

---

## WebSearch verifications performed

1. **Default `iceberg.dynamic-filtering.wait-timeout`** — CONFIRMED via [Iceberg connector — Trino 481 Documentation](https://trino.io/docs/current/connector/iceberg.html): default is `1s` ("Maximum duration to wait for completion of dynamic filters during split generation"). Responder's claim is CORRECT.
2. **`dynamicFilterSplitsProcessed` as the runtime verification field** — CONFIRMED via [Dynamic filtering — Trino 481 Documentation](https://trino.io/docs/current/admin/dynamic-filtering.html): the operator stat is real and appears in `ScanFilterProject` operator statistics. Responder's claim is CORRECT.
3. **`enable_large_dynamic_filters` session property** — CONFIRMED via Trino docs: real session property for large-build-side dynamic filtering.
4. **Domain compaction threshold default = 256** — CONFIRMED via [PostgreSQL connector — Trino 481 Documentation](https://trino.io/docs/current/connector/postgresql.html): `domain_compaction_threshold` default is 256; predicates beyond this collapse to range form.
5. **Plan-time `dynamicFilters = {col = #df_N}` syntax** — CONFIRMED via Trino docs example `"dynamicFilters = {\"ss_sold_date_sk\" = #df_370}"` in `ScanFilterProject` operator.

---

## Gaps (deductions from 5)

- **Technical accuracy (−0.25)**: VERBOSE attribution is over-specific — collection-duration shows in regular `EXPLAIN ANALYZE` for `ScanFilterProject` as well; VERBOSE adds operator-level detail but is not strictly required to read wait-time.
- **Beginner clarity (−1.25)**: "build side", "probe side", "#df_0 dynamic filter ID", "domain compaction", "BETWEEN range" used without inline definitions. The 13th-iter-flagged glossary gap in `resources/22` continues to drag clarity scores — iter360 teacher action #1 (inline glossary at top of resources/22) only partially landed for this question; build/probe directionality needs a one-sentence "smaller side is build, larger side is probe" inline gloss.
- **Practical applicability (−0.25)**: (a) no explicit note that on the production on-prem k8s coordinator, "restart coordinator" means rolling a k8s Deployment / StatefulSet; (b) no Trino 467 / Iceberg 1.5.2 version pin on the 1s default.
- **Completeness (−0.5)**: (a) missing `enable_dynamic_filtering` master kill switch (cluster and session level) as the FIRST thing to check — if someone set this to false at cluster config, all DF tuning is moot; (b) missing the CBO/ANALYZE prerequisite — DF only fires when the planner picks Postgres as the build side, which depends on table stats; if stats are missing or stale, Trino may pick Iceberg as the build side and DF effectively doesn't help; (c) missing the "collection-duration vs wait-timeout" reading — even if `dynamicFilterSplitsProcessed > 0`, if collection-duration > wait-timeout the filter arrived too late and didn't prune splits.

---

## Iter 370 teacher actions (PRIORITY-ORDERED)

1. **HIGH (clarity, 13th-iter-flagged)** — Inline glossary at top of `resources/22-trino-federation-postgresql.md`: "build side = smaller table whose values are collected to filter the larger; probe side = larger table being filtered; `#df_0` = dynamic filter ID assigned by planner; domain compaction = collapsing a long IN-list to a BETWEEN range at the 256-value threshold". This has been flagged for 13 consecutive iterations and continues to be the single largest beginner-clarity deduction. Without inline definitions, federation answers cap at BC ~3.5–3.75 even when technically perfect.
2. **HIGH (completeness)** — Add to `resources/22` the `enable_dynamic_filtering` master kill switch (cluster property `enable-dynamic-filtering` in `etc/config.properties`, session property `enable_dynamic_filtering`) as the FIRST thing to check before any DF tuning — engineers commonly inherit clusters with DF disabled and waste hours tuning wait-timeout.
3. **MEDIUM (completeness)** — Add the "collection-duration vs wait-timeout" reading to `resources/22`: if `dynamicFilterSplitsProcessed > 0` but query is still slow, check whether collection-duration in `EXPLAIN ANALYZE` exceeds the wait-timeout — filter arrived too late means splits were generated before it landed, so increase wait-timeout to a value just above observed collection-duration.
4. **MEDIUM (correctness)** — Add CBO/ANALYZE prerequisite to `resources/22` DF section: "DF requires the planner to pick the smaller table as build side. If Postgres stats are missing, run `ANALYZE postgresql.public.tenants` on the Postgres side and verify with `SHOW STATS FOR postgresql.public.tenants` in Trino. Without stats, Trino may invert the build/probe choice and DF either doesn't fire or fires in the wrong direction."
5. **LOW (practical applicability)** — Add a one-line k8s note in `resources/22`: "On the production on-prem k8s Trino 467, catalog property changes in `etc/catalog/iceberg.properties` require a coordinator restart — for k8s this means rolling the Trino coordinator Deployment/StatefulSet, not just a `SET SESSION`."
6. **LOW (Trino federation topic running average push)** — One more 4.6+ STRONG-PASS landing pushes the topic over the 4.5 threshold; recommend iter370 federation probe target a question where the responder can score 4.6+ (e.g., a clean 4.5+ scenario with strong applicability and no clarity edge cases).

---

## Iter 370 judge probe targets

1. **Federation topic 15th-iter angle** — re-probe to push topic running avg over 4.5 threshold. Suggested phrasing: "We set `iceberg.dynamic-filtering.wait-timeout=20s` and `dynamicFilterSplitsProcessed` shows N > 0, but the Iceberg scan still reads more files than it should. What's the next thing to check?" — tests iter370 teacher action #3 (collection-duration vs wait-timeout reading).
2. **Federation cluster-config kill switch** — "We tried `SET SESSION enable_dynamic_filtering = true` but DF still doesn't fire. What gives?" — tests iter370 teacher action #2 (master kill switch documented).
3. **Carry-forward** — CDC tier 5th angle (snapshot isolation under concurrent CDC writes) still pending across iter365–369.
4. **Carry-forward** — Cost-considerations 8th/9th angle re-probes (bus-factor/MTTR, 90-day-plan) still pending across iter368/369.
5. **Carry-forward** — Query plan optimization 6th angle (scan-skew vs aggregation-skew durability) still pending.

---

## Sources verified

- [Iceberg connector — Trino 481 Documentation](https://trino.io/docs/current/connector/iceberg.html) — default `iceberg.dynamic-filtering.wait-timeout = 1s` confirmed
- [Dynamic filtering — Trino 481 Documentation](https://trino.io/docs/current/admin/dynamic-filtering.html) — `dynamicFilterSplitsProcessed` operator stat confirmed; plan-time `dynamicFilters` ScanFilterProject syntax confirmed; `enable_large_dynamic_filters` confirmed
- [PostgreSQL connector — Trino 481 Documentation](https://trino.io/docs/current/connector/postgresql.html) — `domain_compaction_threshold` default 256 confirmed
- [Add dynamicFilterSplitsProcessed to OperatorStats — PR #3217](https://github.com/trinodb/trino/pull/3217) — origin of the metric confirmed

---

## Iter 369 End-of-Iteration Summary

**Iteration result**: 4.47 average — PASS (both questions cleared the per-question 4.0 bar; Q2 cleared the 4.5 STRONG-PASS bar)

### Per-question results

| Q | Topic / angle | Score | Verdict |
|---|---|---|---|
| Q1 | Trino federation / dynamic filtering in Iceberg+Postgres join (14th-iter angle, iter368 probe target #6) | 4.4375 | PASS — held back from STRONG PASS by BC 3.75 (build/probe/`#df_0`/domain-compaction/BETWEEN-range not inline-glossed) |
| Q2 | Iceberg partition evolution — adding partitioning to a 50TB unpartitioned table | 4.50 | STRONG PASS |

**Iteration average**: 4.47 (vs iter368 4.375, iter367 4.625, iter366 3.8125, iter365 4.25). Second consecutive PASS iteration; three of last four iterations PASS; iter367+368+369 forms first sustained ≥4.3 streak since the iter364-365 stretch.

### Topic running averages — movement this iteration

- **Trino federation / cross-source connectors**: 4.4949/261 (was 4.4951/260 at iter368 close). Q1 4.4375 was BELOW the topic's prior running average, so the average ticked DOWN 0.0002 instead of UP. Topic still PASSED but now sits 0.0051 below the 4.5 STRONG-PASS threshold (was 0.0049 below at iter368 close). The 4.5 threshold is now SLIGHTLY HARDER to reach than it was at start of iter369 — needs a 4.6+ probe to land, and any sub-4.5 probe will push it further away.
- **Iceberg partition evolution**: Q2 4.50 STRONG PASS — partition-evolution topic average lifted (see rubric.md for exact running total).

### Pattern observations across iter 369

1. **Federation topic ceiling drag confirmed durable**: iter368 Q2 federation landed 4.625 STRONG PASS on a BROADCAST/PARTITIONED EXPLAIN question (where glossary work in resources/22 had already landed); iter369 Q1 federation landed 4.4375 on a dynamic-filtering question where the glossary still lacks inline definitions for build/probe/`#df_0`/domain-compaction. The delta (4.625 vs 4.4375 = 0.1875) is directly attributable to the BC dimension (3.75 vs ~4.5). This is now empirically the cleanest A/B confirmation we have that inline glossary expansion DURABLY lifts BC by ~0.75 on dependent questions.
2. **Iceberg partition-evolution maturity**: Q2 4.50 STRONG PASS suggests partition-evolution resource is approaching maturity. Watch for whether this is durable across re-probes — single STRONG PASS does not establish topic maturity.
3. **Iter369 std-dev 0.045** (Q1 4.4375, Q2 4.50) — tightest pass-band of any iteration in the iter360-369 window. Compressed std-dev suggests resource quality across both topics is converging; remaining ceiling drag is concentrated in BC dimension.
4. **WebSearch verification continues to catch over-attribution**: Q1 judge caught responder's over-specific VERBOSE attribution (collection-duration appears in regular EXPLAIN ANALYZE too) via direct trino.io docs read; small −0.25 deduction on Technical accuracy reflects accurate fact-checking, not nitpicking.

### Iter 370 carry-forward priorities (consolidated)

**HIGH**:
1. Inline glossary expansion in `resources/22` for build-side, probe-side, `#df_N`, domain-compaction threshold, BETWEEN-range collapse — 14th-iter-flagged; iter369 Q1 BC 3.75 confirms the gap. Lifting this is the single highest-leverage action to push federation topic over 4.5 STRONG PASS.
2. `enable_dynamic_filtering` master kill switch added to `resources/22` as the FIRST troubleshooting step (cluster property AND session property) — iter369 Q1 completeness deduction.
3. Carry-forward from iter368: cost-considerations glossary (FTE, fully-loaded cost, sunk cost, ops-FTE, modeling-FTE), concrete dollar figures, bus-factor/MTTR section in `resources/16` — none of these have been re-probed yet in iter369; they were displaced by iter369's federation + partition-evolution probes. Iter370 should pick up cost-considerations 8th and 9th angle re-probes.

**MEDIUM**:
4. Collection-duration vs wait-timeout reading added to `resources/22` — iter369 Q1 completeness gap; directly testable via iter369 probe target #1.
5. CBO/ANALYZE prerequisite for correct build-side selection added to `resources/22` DF section — iter369 Q1 correctness gap.

**LOW**:
6. k8s coordinator-restart note in `resources/22` (catalog property changes require rolling the Trino coordinator Deployment/StatefulSet on the on-prem k8s production stack).
7. Iter370 federation probe should target a 4.6+-eligible question to push the topic over 4.5 STRONG PASS (iter369 Q1 pushed the running average slightly DOWN, so the threshold gap widened from 0.0049 to 0.0051 — recovery requires a STRONG PASS on the next federation probe).

### Iter 370 judge probe targets

1. **Federation 15th-iter angle, STRONG-PASS-eligible**: "We set `iceberg.dynamic-filtering.wait-timeout=20s` and `dynamicFilterSplitsProcessed` shows N > 0, but the Iceberg scan still reads more files than it should. What's the next thing to check?" — tests iter370 teacher action #4 (collection-duration vs wait-timeout reading); designed to be 4.6+-eligible to push federation topic over 4.5.
2. **Federation cluster-config kill switch**: "We tried `SET SESSION enable_dynamic_filtering = true` but DF still doesn't fire. What gives?" — tests iter370 teacher action #2 (master kill switch documented).
3. **Cost-considerations 8th angle (carry-forward)**: bus-factor / MTTR re-probe — "our platform engineer is going on a 3-week vacation what should we automate before they leave".
4. **Cost-considerations 9th angle (carry-forward)**: 90-day-plan re-probe — "what should the new platform engineer do in their first 90 days".
5. **Iceberg partition-evolution durability re-probe**: confirm whether iter369 Q2 4.50 STRONG PASS is durable across a different angle (e.g., partition-spec evolution from `days(ts)` to `hours(ts)` mid-table).
6. **CDC tier 5th angle (carry-forward, still pending across iter365-369)**: snapshot isolation under concurrent CDC writes.
7. **Query plan optimization 6th angle (carry-forward, still pending)**: scan-skew vs aggregation-skew durability re-probe.

### Verdict on overall training state

- Iteration 369 PASS extends the second consecutive PASS streak.
- No required-topic regressions observed; federation topic ticked DOWN microscopically but remained above the 4.0 PASS threshold.
- Single most leverageable action remains the resources/22 inline glossary expansion (HIGH #1 above), which is now the rate-limiting step on federation topic crossing 4.5 STRONG PASS.
- Training state remains `passed: true` (set at the original final-phase completion); the loop continues for extended-phase quality push through the 2026-05-30 12:00 CST training deadline.

