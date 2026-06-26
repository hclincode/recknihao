# Iter1136 Feedback — 4.125 PASS + LIGHT FIX-A WARRANTED: Q1 PERCENT_RANK direction slip RECURRED on direct re-probe; iter1135 watch escalates

## Verdict summary

| Item | Status |
|---|---|
| Iter average | 4.125 PASS (margin +0.625 above 3.5 floor) |
| Q1 PERCENT_RANK direction on "top team near 100" badge | **DEFECT 2.125 — RECURRENCE of iter1135 Q2 slip; explicit re-probe; LIGHT FIX-A warranted** |
| Q2 COUNT(DISTINCT company_id) GROUP BY event_type + last-month filter | CLEAN 4.5 — single-arg COUNT DISTINCT correct; minor "last month" upper-bound interpretation gap |
| Q3 any_match(tags, t -> contains(list, t)) + array_intersect alternative | CLEAN 4.875 — both forms valid; arrays_overlap omission is a minor completeness note |
| Q4 on-prem-no-per-query-cost + storage/cluster/FTE drivers | CLEAN 5.0 — prod_info MinIO/on-prem stack reconciled correctly |
| New defects this iter | 1 (Q1 — RECURRING from iter1135 Q2) |
| Resource defects discovered | 0 (canonicals at r07 §3939 cume_dist + §3962 direction guardrail present + correct — findability gap on customer-facing phrasing) |
| Recommendation | **LIGHT FIX-A** (escalate per iter1135 watch rule: add keyword-magnetic LEAD card on customer-facing "you beat X% of peers / leaderboard percentile / top near 100" phrasing pointing to existing canonicals) |

## Q1 RECURRENCE VERDICT — YES, SLIP RECURRED ON EXPLICIT DIRECT RE-PROBE

iter1135 Q2 (customer "$45k → spent more than 73% of peers" with PERCENT_RANK ORDER BY total_spent DESC) was classified RESPONDER-ONE-OFF + WATCH with escalation rule: "if RECURS on similar customer-facing percentile-message phrasing → LIGHT FIX-A".

iter1136 Q1 directly probes the same direction-to-semantic mapping with the requirement spelled out explicitly:
- "in-app badge: 'Your team ran more reports than X% of all teams'"
- "TOP team must see ~100, low team ~0"
- "which sort direction for top=near-100?" — explicit direction question

Responder:
1. Recommends `ROUND(100.0 * PERCENT_RANK() OVER (ORDER BY report_count DESC), 1)`.
2. Correctly states the math: "With ORDER BY report_count DESC, the highest-reporting team gets PERCENT_RANK = 0.0".
3. Then claims "A team with percentile = 95 has beaten 95% of all teams" — under DESC a row with percent_rank 0.95 sits at rank ≈ 0.95*(N-1)+1 (deep in the DESC list = LOW report_count = beat only ~5%). BACKWARDS.
4. Warning: "if you accidentally sort ascending, the numbers flip — the top team would show near 0, not 100" — INVERTED. Under ASC the TOP team is LAST → percent_rank = 1.0 → ×100 → ~100, which IS what the engineer asked for.

The TOP team requirement is ~100; the recommended DESC gives the TOP team ~0. The recommendation is exactly opposite to the explicit requirement.

This is the 2nd consecutive instance (iter1135 Q2 + iter1136 Q1) on customer-facing percentile-message phrasing where the responder uses DESC + "beat X% of peers" labeling. Per the iter1135 escalation rule, recurrence triggers LIGHT FIX-A.

**Source-verified.** PERCENT_RANK = (r-1)/(n-1) per [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html). Under DESC, highest-metric row → rank 1 → percent_rank 0.0. CUME_DIST = preceding-or-peer / total → highest-metric row under ORDER BY metric ASC → 1.0. WebFetch confirmed both formulas this iter.

## Per-question scoring

### Q1 (2.125) — "Your team ran more reports than X% of all teams" leaderboard percentile, top team near 100 — DIRECTION RECURRENCE

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 1.0 | Three compounding errors. (a) Recommends `PERCENT_RANK() OVER (ORDER BY report_count DESC)` — under DESC the TOP team gets percent_rank 0.0 → ROUND(100.0 * 0.0, 1) = 0.0, the OPPOSITE of the explicit "top team near 100" requirement. (b) Annotation "percentile = 95 has beaten 95% of all teams" — backwards under DESC: a row at percent_rank 0.95 sits 95% of the way DOWN the DESC list = LOW report_count = beaten only ~5% of peers. (c) Warning "if you accidentally sort ascending, the numbers flip — the top team would show near 0" — INVERTED: under ASC the TOP team is LAST row → percent_rank 1.0 → ×100 → ~100, which is the GOAL. Correct shapes for "top team near 100": `cume_dist() OVER (ORDER BY report_count)` (top → 1.0, no scaling logic) OR `percent_rank() OVER (ORDER BY report_count ASC)` OR `(rank-1)/(count_over-1) * 100` with explicit ASC. Engineer explicitly asked "does it matter which direction?" and got the answer wrong. |
| Clarity | 4.0 | Writing is crisp and the math statement is internally consistent with the formula — but the customer-facing labeling and direction recommendation are wrong. A confident, well-organized wrong answer. |
| Applicability | 1.0 | Engineer who copies this ships the in-app badge where the BEST team sees "Your team ran more reports than 0% of all teams" and the WORST team sees "...more than 100% of all teams" — directly customer-visible inversion. The explicit "top near 100" requirement is violated. |
| Completeness | 2.5 | Covers function (percent_rank), addresses the direction sub-question (gets it wrong), mentions CUME_DIST in passing but doesn't navigate to it as the cleaner answer (cume_dist + ORDER BY ASC gives [1/N → 1.0] with no scaling logic and no direction trap). Misses r07 §3939-3956 cume_dist-at-or-below LEADING CANONICAL AND r07 §3962-4023 PERCENT_RANK direction guardrail despite both being present and exactly addressing the question shape. |

**Defect classification: RECURRING-DEFECT, escalate per iter1135 watch rule.**

iter1135 Q2 ("$45k → 73% of peers" with DESC) was first instance, classified responder-one-off + watch. iter1136 Q1 is the explicit re-probe with even clearer requirement ("TOP team near 100") and even more pointed direction sub-question ("does it matter ASC or DESC?"). Same exact error mode: DESC selected + "beat X% of peers" labeling + inverted-warning. The canonical (r07 §3939 cume_dist LEADING + §3962 direction guardrail) is present and correct, but is NOT reached by the customer-facing phrasing. This is a findability gap, not a content gap — LIGHT FIX-A is the right scope (additive keyword-magnetic LEAD card, no removal/rewrite of existing canonicals).

### Q2 (4.5) — unique companies per event_type last month

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 4.5 | `COUNT(DISTINCT company_id) GROUP BY event_type` is correct single-arg Trino 467 form (memory: COUNT-DISTINCT-Single-Arg). Date filter `>= date_trunc('month', current_date) - INTERVAL '1' MONTH` correctly anchors at first day of previous month. Minor gap: if "last month" means the previous calendar month only (most common SaaS interpretation), an upper bound `AND occurred_at < date_trunc('month', current_date)` is needed — without it, the query also includes the current month-to-date. Both readings ("trailing window from start of previous month" vs "previous calendar month closed") are defensible; the responder picked one without flagging the ambiguity. |
| Clarity | 5.0 | Clean single query, no extra noise. |
| Applicability | 4.5 | Runs correctly under one of two valid "last month" readings; if engineer wanted closed previous calendar month, they need to add the upper bound — but the omission is a minor scope clarification, not a bug. |
| Completeness | 4.0 | Doesn't flag the "last month = closed previous calendar month vs trailing window" ambiguity, and doesn't mention `approx_distinct(company_id)` as a high-cardinality fallback (worth a one-line aside for SaaS scale on events tables). |

### Q3 (4.875) — tags array shares ANY element with given list

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | Both forms valid in Trino 467. `any_match(tags, t -> contains(ARRAY[...], t))` verified at [trino.io/docs/current/functions/array.html](https://trino.io/docs/current/functions/array.html) — any_match signature `any_match(array(T), function(T,boolean)) → boolean`. `cardinality(array_intersect(tags, ARRAY[...])) > 0` also valid — array_intersect returns intersection without duplicates. Correct rejection of UNNEST+join as unnecessary. |
| Clarity | 5.0 | Two clean alternatives, both inline. |
| Applicability | 5.0 | Either form drops into a WHERE clause. |
| Completeness | 4.5 | **Completeness improvement opportunity (not a defect):** Trino 467 has a dedicated `arrays_overlap(x, y) → boolean` built-in that is THE most direct form for "shares any element" — `arrays_overlap(tags, ARRAY['power-user','beta-tester','enterprise'])`. Mentioning it as the leading form (with any_match as the lambda-flexible fallback and array_intersect as the "and-give-me-the-intersection-too" form) would be the canonical-quality answer. The given forms work; arrays_overlap is the cleanest. |

### Q4 (5.0) — dashboard cost drivers on Iceberg, what to attack first

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | Correctly reconciles "cloud bill" phrasing with the prod_info.md on-prem MinIO + k8s Trino stack — no per-query pricing (vs Athena/BigQuery/Snowflake cloud DWs). Real drivers correctly enumerated: (a) storage footprint (S3-equivalent MinIO bytes) controllable via `expire_snapshots` + `optimize` / file compaction; (b) cluster CPU/RAM as fixed sunk cost; (c) engineering FTE as the dominant ongoing cost. Within-query drivers (partition pruning, join order, result size) correctly identified. "Lever is avoiding unnecessary queries via rollups/caching, not per-query tuning" matches the fixed-cluster cost model. Starting with `expire_snapshots` is the right first attack given Iceberg's snapshot-accumulation default (every commit retains old snapshots forever otherwise → S3 storage grows linearly with commits, not table size). |
| Clarity | 5.0 | Clean breakdown by cost category (per-query/cluster/FTE) + within-query lever ranking. |
| Applicability | 5.0 | Engineer can immediately: (a) check `system.metadata.materialized_view_properties` or `SELECT * FROM "tbl$snapshots"` to count snapshot rows, (b) run `ALTER TABLE x EXECUTE expire_snapshots(retention_threshold => '7d')`, (c) profile MinIO bucket growth, (d) skip the "tune each query" trap. |
| Completeness | 5.0 | Covers cost-model framing (no per-query pricing), driver enumeration, within-query factors, and first-attack lever — full answer scope. |

## Iter summary table

| Q | Accuracy | Clarity | Applicability | Completeness | Avg |
|---|---|---|---|---|---|
| Q1 | 1.0 | 4.0 | 1.0 | 2.5 | 2.125 |
| Q2 | 4.5 | 5.0 | 4.5 | 4.0 | 4.500 |
| Q3 | 5.0 | 5.0 | 5.0 | 4.5 | 4.875 |
| Q4 | 5.0 | 5.0 | 5.0 | 5.0 | 5.000 |
| **Iter avg** | | | | | **4.125 PASS** |

## Topics updated

- **Analytical query patterns on Iceberg+Trino** (Q1, percentile direction recurrence): 4.4776/87 → (4.4776×87 + 2.125)/88 = (389.5512 + 2.125)/88 = **4.4509/88 PASSED** (−0.0267 drag from Q1 direction recurrence; margin +0.9509 still safely above 3.5).
- **SQL query best practices for OLAP** (Q2, COUNT-DISTINCT GROUP BY single-arg + Q3, array overlap forms): 4.5550/196 → after Q2 (4.5550×196 + 4.5)/197 = (892.78 + 4.5)/197 = **4.5547/197** → after Q3 (4.5547×197 + 4.875)/198 = (897.2759 + 4.875)/198 = **4.5563/198 PASSED** (+0.0013).
- **Cost considerations for analytical workloads at SaaS scale** (Q4, on-prem-no-per-query-cost + expire_snapshots first lever): 4.2759/22 → (4.2759×22 + 5.0)/23 = (94.0698 + 5.0)/23 = **4.3074/23 PASSED** (+0.0315).

ALL required topics REMAIN PASSED.

## LIGHT FIX-A SPEC — keyword-magnetic LEAD card on customer-facing percentile-message phrasing

**Why a fix is warranted (and not NO-OP):** iter1135 Q2 was a watch-classified responder-one-off with an explicit escalation rule ("if RECURS on similar phrasing → LIGHT FIX-A"). iter1136 Q1 is a direct, explicit re-probe with even clearer requirement language ("TOP team near 100", "does it matter ASC or DESC?") and the same exact direction-inversion failure mode. r07 §3939-3956 (cume_dist LEADING CANONICAL) and r07 §3962-4023 (PERCENT_RANK direction guardrail) ARE present and correct — both directly answer the question if reached. The reach failure is on the customer-facing phrasing (in-app badge / "you beat X% of peers" / leaderboard / top-near-100), not on a content gap. LIGHT FIX-A = additive keyword-magnetic LEAD card; no removal, no rewrite of existing canonicals.

**Card location:** insert before r07 §3939 (cume_dist LEADING CANONICAL) as a question-shape-router that LEADS to both existing canonicals.

**Card anchors (keyword-magnetic):**
- "you beat X% of peers" / "beat X% of customers"
- "your team ran more X than Y% of teams" / "you used more than X% of teams"
- "leaderboard percentile" / "percentile badge" / "in-app percentile message"
- "top performer near 100" / "top team should see ~100" / "show the top as ~100"
- "customer-facing percentile" / "user-facing percentile"

**Card body (LEAD):**

> ### Customer-facing percentile messages — "you beat X% of peers" / "top performer near 100"
>
> When the UI shows a row like "Your team ran more reports than 87% of all teams" or "You spent more than 73% of customers", the **top performer must read ~100** and the bottom ~0. There are two correct shapes; pick by readability:
>
> **Shape A (preferred — no scaling, no direction trap):**
> ```sql
> ROUND(100.0 * cume_dist() OVER (ORDER BY report_count), 1) AS percent_of_peers_at_or_below
> ```
> Reasoning: `cume_dist() = preceding-or-peer / total`. Top team is last in ASC order → 1.0 → ×100 → ~100. Low team → ~1/N → near 0. No direction logic to get wrong.
>
> **Shape B (percent_rank — direction matters):**
> ```sql
> ROUND(100.0 * percent_rank() OVER (ORDER BY report_count ASC), 1) AS percent_of_peers_below
> ```
> Reasoning: `percent_rank = (rank-1)/(n-1)`. Under **ASC**, top team is last row → rank n → 1.0 → ×100 → ~100. Bottom is first → 0.0 → 0.
>
> **DO NOT WRITE — the inverted DESC form for this phrasing:**
> ```sql
> -- WRONG for "top team near 100" / "you beat X% of peers" labeling:
> ROUND(100.0 * percent_rank() OVER (ORDER BY report_count DESC), 1) AS percent_of_peers
> ```
> Under DESC, the TOP team is FIRST row → rank 1 → percent_rank 0.0 → ×100 → **~0**, which is the OPPOSITE of what the in-app badge needs. The badge label "beat X% of peers" pairs with ASC sort or with cume_dist, NEVER with DESC.
>
> See also: [PERCENT_RANK direction guardrail §3962-4023](#leading-canonical--percent_rank--ntile-direction-guardrail-iter635--top-x-by-metric-inversion-trap) for the full direction-decision table; this card is the customer-facing-message specialization.

**Topic row to update:** Analytical-query-patterns Iceberg+Trino (already drags from this iter's Q1; LIGHT FIX-A should land this iter or next).

**Cross-ref also from:** r07 §3962+ (existing PERCENT_RANK direction guardrail) — add one-line forward pointer to the new customer-facing-message card so engineers landing on the guardrail also see the canonical question-shape match.

## Source-verified absences / non-defects this iter

- Zero ::/QUALIFY/false-semi-join/fabricated-fn/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT/CAST-truncate/EXECUTE-rollback-on-467/Spark-Oracle-spillover/imported-prior/GREATEST-NULL-Postgres/array_sum/`->`/`->>`-JSON/DATEDIFF-dialect-import/multi-arg-COUNT-DISTINCT/ts-minus-ts/over-warning/multi-clause-ADD-COLUMN/contains_sequence-array_position-arithmetic/partition-column-COUNT-data-file-folklore/population-vs-per-group-percentile/dedup-tied-tuple recurrence.
- Q2 COUNT-DISTINCT single-arg form correct (no multi-arg slip).
- Q3 any_match + array_intersect both verified at [trino.io/docs/current/functions/array.html](https://trino.io/docs/current/functions/array.html); arrays_overlap exists as the most-direct form (completeness opportunity, not a defect).
- Q4 on-prem-no-per-query-cost framing + expire_snapshots first-attack lever = correct for prod_info MinIO + k8s Trino stack.

## Pattern observation

iter1135 Q2 (PERCENT_RANK DESC + "spent more than 73% of peers") and iter1136 Q1 (PERCENT_RANK DESC + "your team ran more reports than X% of all teams", top-near-100 EXPLICIT) — same error mode, two consecutive iters, direct re-probe. The canonical content (r07 §3939 cume_dist + §3962 direction guardrail) is present and correct; the responder is not navigating to either on the customer-facing-message phrasing variant. This is a textbook findability gap — the right intervention is a keyword-magnetic LEAD card with the customer-facing anchors that pulls to existing canonicals, NOT a content rewrite.

Discipline contrast: the iter1135 NO-OP+WATCH was the correct call at first instance (per first-instance discipline + 6 prior precedents). Now at second instance on direct re-probe, the watch escalates to LIGHT FIX-A per the documented rule. This is the watch system working as designed — not over-churn, not under-correction.

## Re-probe queue

1. **After LIGHT FIX-A lands**: re-probe with a 3rd customer-facing percentile-message phrasing — e.g., "we want to show 'you logged more sessions than X% of teams' on the dashboard, top team should see ~100" — to confirm the new card pulls the responder to cume_dist / percent_rank ASC. If the new card works, close the watch stream.
2. Storage-tiering 12th angle (still thinnest required-topic at 4.0739; untouched this iter).
3. dbt-snapshots SCD2 17th angle (untouched).
4. Cost-considerations 24th angle (lifted +0.0315 this iter; sustain).
5. Q3 follow-up: probe a similar array-overlap phrasing to see if responder reaches `arrays_overlap` natively or stays on any_match — completeness check, not defect.
6. Q2 follow-up: probe "last quarter" or "last 7 days" phrasing to see if responder consistently picks the closed-window or trailing-window interpretation.

## Thinnest-margin order after iter1136

| Topic | Avg / N | Margin to 3.5 |
|---|---|---|
| Storage-tiering | 4.0739 / 11 | +0.5739 (thinnest required-topic; untouched) |
| dbt-snapshots SCD2 | 4.1526 / 16 | +0.6526 (untouched) |
| Query-perf-basics | 4.1771 / 23 | +0.6771 (untouched) |
| Cost-considerations | **4.3074 / 23** | +0.8074 (Q4 lift) |
| Query-perf-regression-diagnosis | 4.3108 / 20 | +0.8108 (untouched) |
| Analytical-query-patterns | **4.4509 / 88** | +0.9509 (Q1 drag; still PASS, watch escalated to LIGHT FIX-A) |
| Oracle-migration | 4.4561 / 115 | +0.9561 (untouched) |
| Iceberg-maintenance | 4.4800 / 179 | +0.9800 (untouched) |
| Federation | 4.5024 / 312 | +1.0024 (untouched, fragile-PASS preserved) |
| SQL-best-practices-OLAP | **4.5563 / 198** | +1.0563 (Q2+Q3 lifts) |
| CBO/ANALYZE | 4.6105 / 22 | +1.1105 (untouched) |
| Improving-complex-SQL-perf-dbt | 4.6111 / 25 | +1.1111 (untouched) |

## RECOMMENDATION = LIGHT FIX-A

Commit rubric + feedback + add the customer-facing-percentile-message LEAD card at r07 §3939 (insert position immediately before existing cume_dist LEADING CANONICAL). NO removal or rewrite of existing canonicals.

Reasoning:
- iter1135 Q2 + iter1136 Q1 = 2 consecutive direct-re-probe instances of the same direction misapplication on customer-facing percentile phrasing.
- iter1135 escalation rule (recurrence → LIGHT FIX-A) is met.
- r07 §3939 cume_dist + §3962 PERCENT_RANK direction guardrail are present and correct — content gap is ZERO; findability gap on customer-facing phrasing is the actual defect.
- Additive keyword-magnetic LEAD card at the canonical question-shape ("you beat X% of peers" / "top team near 100" / "leaderboard percentile") with explicit DO-NOT-WRITE defang of the DESC inversion form, plus forward pointer to existing direction guardrail. No churn risk to other neighbors.
- Iter avg 4.125 PASS (margin +0.625); Q2/Q3/Q4 clean; the LIGHT FIX-A is scoped to one card, low intervention surface.

## Source citations

- [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html) — PERCENT_RANK `(r-1)/(n-1)`; CUME_DIST "preceding-or-peer / total". Confirms Q1 direction inversion: DESC gives top row percent_rank 0.0 (responder's recommendation = top team ~0, opposite of "near 100" requirement).
- [trino.io/docs/current/functions/array.html](https://trino.io/docs/current/functions/array.html) — `any_match(array(T), function(T,boolean)) → boolean`, `array_intersect(x,y) → array`, `arrays_overlap(x,y) → boolean`. Confirms Q3 forms valid; arrays_overlap exists as completeness improvement.
- r07 §3939-3956 LEADING CANONICAL cume_dist at-or-below — present, correct, NOT REACHED by responder on customer-facing phrasing (findability gap).
- r07 §3962-4023 PERCENT_RANK direction guardrail with DO-NOT-WRITE inverted-prose defang — present, correct, NOT REACHED on customer-facing phrasing.
- prod_info.md §"Production environment" — on-prem k8s Trino + MinIO confirms Q4 no-per-query-cost framing.
