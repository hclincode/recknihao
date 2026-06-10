# Judge Feedback — iter969

**Date**: 2026-06-11 (EXTENDED PHASE, NO-OP breadth sweep)
**Overall**: 4.0625 PASS (margin +0.5625; OVERALL AVERAGE governs, no per-Q veto)

Per-Q: Q1 3.0625 / Q2 4.875 / Q3 4.875 / Q4 3.4375 = 16.25/4 = 4.0625

All dialect/logic verified BOTH directions vs trino.io/docs/467 (aggregate.html FILTER (WHERE) + count(); window.html RANK() OVER (PARTITION BY ... ORDER BY ...); language/types.html INTERVAL '30' DAY) + WebSearch 2026-06-11 — NOT against resources/. Column-scope traced on Q1 and Q4-first-form.

---

## Q1 — Rank reps by quota attainment (division + ranking) — 3.0625 (Acc 2.0 / Comp 3.5 / Clar 3.75 / Act 3.0)

**APPROACH CORRECT, QUERY WON'T COMPILE.** `100.0 * SUM(amount) / q.target` for decimal division and `RANK() OVER (PARTITION BY quarter ORDER BY pct_of_quota DESC)` single-pass ranking are the right tools (RANK syntax VERIFIED window.html; 100.0* decimal promotion correct).

**CONFIRMED BUG — MISSING-COLUMN-IN-CTE-PROJECTION (column-scope slip):** The `rep_performance` CTE SELECT list is `(rep_id, actual_revenue, quota_target, pct_of_quota)`. `q.quarter` appears in the CTE's `GROUP BY rep_id, q.target, q.quarter` but is **NOT projected** in the SELECT list. The outer query references `quarter` in BOTH `RANK() OVER (PARTITION BY quarter ...)` AND `ORDER BY quarter`. Since `quarter` is not an output column of the CTE, this **FAILS with an unresolved/column-not-found error in Trino**. TRACED: outer query can only see {rep_id, actual_revenue, quota_target, pct_of_quota} — `quarter` resolves to nothing. Fix is trivial: add `q.quarter` to the CTE SELECT.

**RESOURCE-vs-SLIP = PURE RESPONDER SYNTHESIS SLIP.** r07 L3812 teaches `RANK() OVER (PARTITION BY tenant_id ORDER BY amount DESC)` correctly; L2829 teaches Top-N-per-group RANK with a partition column properly carried. No resource teaches a CTE that omits its partition/order column from the projection. The responder dropped a column from the projection while writing — a per-instance assembly slip, NOT a content/findability defect. NO resource edit.

Acc 2.0 for the won't-compile query (real error, not cosmetic); structure/approach is right, so not a 1. Clarity/Act dinged because an engineer who copies this hits an error before getting value.

---

## Q2 — % invoices unpaid past due, by month (one query or two) — 4.875 (Acc 5.0 / Comp 4.75 / Clar 4.75 / Act 5.0)

**CLEAN + CORRECT.** Answers the "one query" thrust directly: a single GROUP BY with `COUNT(*)` total + `COUNT(*) FILTER (WHERE due_date < CURRENT_DATE AND is_paid = false)` for past-due-unpaid + `ROUND(100.0 * .../COUNT(*), 2)` for the percentage — no two-query/self-join needed.

VERIFIED: `COUNT(*) FILTER (WHERE ...)` valid in 467 (aggregate.html — "FILTER keyword removes rows from aggregation with a WHERE clause"); `is_paid = false` boolean comparison valid; `DATE_TRUNC('month', due_date)` valid grouping; `100.0*` decimal promotion; `ROUND(x, 2)`. Correctly notes CASE WHEN is an equivalent alternative (correct secondary this time, matches r07 L1317 guidance). Trivial -0.25 Comp: did not mention a NULL `is_paid` edge case, immaterial.

---

## Q3 — DISTINCT carriers per order (count unique within a group) — 4.875 (Acc 5.0 / Comp 4.75 / Clar 4.75 / Act 5.0)

**CLEAN + CORRECT.** `COUNT(DISTINCT p.carrier) ... LEFT JOIN parcels ... GROUP BY o.order_id` is exactly right. VERIFIED: COUNT(DISTINCT col) is single-arg/valid in 467; LEFT JOIN preserves orders with no parcels, and `COUNT(DISTINCT)` of an all-NULL group returns **0** (count is a NULL-exception aggregate), so no-parcel orders correctly show 0. Correctly volunteers the LEFT-JOIN-keeps-zero-count rationale. Directly answers "count unique within a group." Trivial -0.25 Comp only.

---

## Q4 — Fraction of active users with >=5 distinct login days (two passes or one) — 3.4375 (Acc 2.75 / Comp 4.0 / Clar 3.0 / Act 4.0)

**CORRECT CONCISE FORM PRESENT; FIRST FORM BROKEN (over-complicated/broken-secondary tic).**

The SECOND "more concise" form is **CORRECT**: `SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE distinct_login_days >= 5) / COUNT(*), 2) FROM (SELECT user_id, COUNT(DISTINCT login_date) AS distinct_login_days FROM daily_logins WHERE login_date >= CURRENT_DATE - INTERVAL '30' DAY GROUP BY user_id)`. TRACED: inner subquery yields one row per user active in the window with their distinct-day count (denominator COUNT(*) = active users with >=1 login in window); numerator = those with >=5 distinct days; `INTERVAL '30' DAY` VERIFIED valid (types.html). A copyable correct answer exists.

**CONFIRMED BUG — BROKEN FIRST MULTI-CTE FORM (column-scope + malformed aggregate):** The final SELECT is `SELECT ROUND(100.0 * five_plus_days.active_with_5plus_days / COUNT(active_users.user_id), 2) FROM five_plus_days, (SELECT COUNT(*) AS active_users FROM active_users) active_users`. Two problems:
1. The cross-joined subquery aliased `active_users` is `(SELECT COUNT(*) AS active_users FROM active_users)` — it exposes ONLY a column named `active_users` (a bigint count), NOT `user_id`. So `COUNT(active_users.user_id)` references a **non-existent column → unresolved-column error**.
2. `COUNT(active_users.user_id)` is an aggregate applied in a final SELECT over a 2-row cross join (each side a single-row count) with NO GROUP BY alongside the bare scalar `five_plus_days.active_with_5plus_days` — malformed aggregation. The denominator should just be the scalar `active_users` count column, no COUNT() wrapper.

So the first form WON'T RUN. The responder over-built a 3-CTE + cross-join scaffold, mis-wired the column reference, then offered the genuinely-correct compact form as an afterthought.

**RESOURCE-vs-SLIP = PURE RESPONDER SYNTHESIS SLIP.** r07 L1317 teaches the `COUNT(*) FILTER (WHERE ...)` conditional-count idiom; the count-distinct-then-fraction pattern is well-supported. The broken first form is the recurring broken-secondary / over-complication / mid-answer-churn tic (iter936/943/948/950/954/958/959/960/961/962/963/964/965/966/968 family), NOT a content/findability defect. NO resource edit (re-probe-don't-churn; adjacent over-attraction risk).

Acc 2.75 (broken first form ships an unresolved-column error and malformed aggregate) but recognizes a correct copyable concise form is present, so above a 2. Clarity 3.0 for leading with the broken complex form before the correct simple one.

---

## SCOPE / VERDICTS

- **Q1 missing-quarter-column verdict**: REAL won't-compile bug — `quarter` used in outer PARTITION BY + ORDER BY but never projected by the `rep_performance` CTE. PURE RESPONDER SLIP (resources teach RANK-over-divided-metric correctly at r07 L3812/L2829; approach is right, projection slip on assembly). NO resource defect.
- **Q4 broken-first-form-but-correct-concise-form verdict**: First multi-CTE form WON'T RUN (`active_users.user_id` unresolved on the count-only aliased subquery + malformed aggregate over no-GROUP-BY cross join). The "more concise" second form IS CORRECT and copyable. PURE RESPONDER SLIP (broken-secondary/over-complication tic; r07 L1317 FILTER idiom findable + correct). NO resource defect.
- Q2 / Q3 CLEAN + CORRECT, score high.
- Known tics check: NO QUALIFY, NO semi-join mislabel, NO MAX(varchar)-as-latest, NO percent_rank inversion, NO fabricated rule/property names this sweep. NEW pattern instances: missing-column-in-CTE-projection (Q1) + over-complicated-broken-first-form (Q4) — both column-scope/assembly slips in the broken-secondary family.

## RECOMMENDATION — DEFAULT NO-OP

Overall 4.0625 PASS (margin +0.5625, weaker than recent 4.5-4.9 sweeps due to TWO won't-compile queries, but Q2/Q3 clean and Q1-approach/Q4-concise-form correct). Both bugs are per-instance Haiku synthesis slips against correct/findable resources — no single resource fix, and adding cards risks adjacent over-attraction (feedback_new_card_over_attracts_adjacent.md). Per feedback_synthesis_ceiling_stop_churning.md + feedback_responder_broken_secondary_alternative.md these are the residual Haiku assembly ceiling, not gaps.

LIGHT FIX-A ONLY IF a column-scope slip (partition/order column omitted from a CTE projection, OR a cross-joined scalar subquery column referenced that isn't exposed) RECURS on a different surface in the next 2 sweeps. Until then: re-probe (a) another rank-over-ratio Q (confirm the partition column is carried into the CTE projection), (b) another fraction-meeting-threshold Q (confirm the responder reaches the clean COUNT(*) FILTER form without the broken cross-join scaffold).

PINS REINFORCED:
- **rank-by-attainment = `100.0*SUM(metric)/target` (decimal promotion) + `RANK() OVER (PARTITION BY <grp> ORDER BY ratio DESC)`; CARRY the partition/order column INTO the CTE SELECT projection — a column used in outer PARTITION BY/ORDER BY but only in the CTE GROUP BY (not projected) is an UNRESOLVED-COLUMN error in 467**
- **one-query count + % = `COUNT(*)` total + `COUNT(*) FILTER (WHERE cond)` subset + `ROUND(100.0*subset/total, 2)`; FILTER valid on all aggregates (aggregate.html); no two-query/self-join needed**
- **distinct-within-group = `COUNT(DISTINCT col) ... GROUP BY grp`; LEFT JOIN preserves empty groups and COUNT(DISTINCT) of an all-NULL group = 0**
- **fraction-meeting-threshold = `COUNT(*) FILTER (WHERE per_user_metric >= N) / COUNT(*)` over a `(SELECT user_id, COUNT(DISTINCT day) ... WHERE window GROUP BY user_id)` subquery — one pass over the per-user rollup; a cross-joined scalar count subquery exposes ONLY its aliased count column (referencing `.user_id` on it = unresolved column); INTERVAL '30' DAY valid (types.html)**
- **broken-secondary / over-complication / column-scope-slip meta-pattern persists — leads/concise-forms correct, the elaborate alternative ships a won't-compile error; per-instance Haiku synthesis slip NOT a resource defect**

Federation r22 §13.x hard-locked, NOT probed (OVERRIDDEN). MUST NOT bump training/state.json (already 969; passed=true preserved; final_iterations_remaining 0).
