# iter974 Judge Feedback — EXTENDED PHASE breadth sweep

**OVERALL 4.50 STRONG PASS** (Q1 4.69 / Q2 4.50 / Q3 4.81 / Q4 4.00 = 18.00/4 = 4.50; margin +1.00; OVERALL AVERAGE governs, no per-Q veto).

All 4 Qs verified BOTH directions vs trino.io/docs/467 (functions/datetime.html date_trunc return type, sql/select.html default window frame, functions/aggregate.html count distinct) + WebSearch on Trino decorrelation/anti-join, 2026-06-17 — NOT against resources/. Q2 conversion logic TRACED on a concrete example. Prod stack (Trino 467 Iceberg + Hive Metastore, on-prem MinIO) — answers fit.

---

## Q1 — DISTINCT users per day this month — 4.69 (Acc 4.5 / Clar 4.75 / App 4.75 / Comp 4.75)
LEAD CORRECT. `SELECT date_trunc('day', login_timestamp) AS login_day, COUNT(DISTINCT user_id) ... GROUP BY 1 ORDER BY 1`.
- VERIFIED datetime.html: `date_trunc(unit, x) → [same as input]`; with a TIMESTAMP arg it returns a **TIMESTAMP truncated to midnight** (`2022-10-20 00:00:00.000`), **NOT a DATE**. The responder's claim "returning a DATE value" is a **minor type imprecision** — the grouping/ordering still work correctly because all same-day timestamps collapse to the same midnight TIMESTAMP. Only a small accuracy ding.
- COUNT(DISTINCT user_id) (not COUNT(*)) — CORRECT, exactly the right call for "distinct users".
- GROUP BY 1 ordinal — VALID Trino.
- partitioning=ARRAY['day(login_timestamp)'] — valid Iceberg transform (matches r09 canonical).
- MINOR completeness: did NOT add a `WHERE login_timestamp >= date_trunc('month', current_date)` scope-to-"this-month" filter (Q said "each day this month"). Small comp ding; the per-day aggregation is otherwise exactly what was asked.

## Q2 — % of month's signups who ever purchased — 4.50 (Acc 4.5 / Clar 4.5 / App 4.5 / Comp 4.5)
LEAD CORRECT. `WITH signup_purchase_matches AS (SELECT DISTINCT s.user_id FROM signups s LEFT JOIN orders o ON o.user_id=s.user_id WHERE o.order_id IS NOT NULL) SELECT COUNT(*) total_signups, (subquery count) signups_with_purchase, 100.0*(subquery)/COUNT(*) pct FROM signups`.
- TRACE: LEFT JOIN + `o.order_id IS NOT NULL` + DISTINCT = DISTINCT signup-users with >=1 matching order = semantic SEMI-JOIN. pct = 100.0 * matched / COUNT(*) all signups. CORRECT if signups is one-row-per-user. 100.0* decimal promotion correct (avoids integer-division truncation).
- TERMINOLOGY: calls LEFT JOIN+IS NOT NULL+DISTINCT a "semi-join pattern" — this is **ACCEPTABLE pattern-naming**, NOT the iter960/963 false-mechanism error. It does NOT claim Trino plans it as a SemiJoinNode; it describes the SEMANTICS, which are genuinely those of a semi-join. Borderline-acceptable, not flagged as a mislabel.
- "LEFT JOIN+filter clearer than INNER JOIN" — defensible stylistic claim; an INNER JOIN + DISTINCT would be equally correct.
- MINOR completeness: did NOT scope signups to "January / a given month" (`WHERE date_trunc('month', s.signup_date) = ...`). The Q was somewhat general ("in a given month... like January"), so this is a minor comp ding, not a lead defect.

## Q3 — running total of revenue across days — 4.81 (Acc 5 / Clar 4.75 / App 4.75 / Comp 4.75)
CLEAN. `SUM(revenue) OVER (ORDER BY day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`.
- VERIFIED sql/select.html: this is a correct Trino running total. Explicit ROWS frame = row-by-row cumulative.
- TIED-DATES claim VERIFIED CORRECT: default frame (when omitted, ORDER BY present) = **RANGE UNBOUNDED PRECEDING = RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW**, which "contains all rows from the start of the partition up to the **last peer** of the current row" — i.e., tied/same-day rows ALL get the SAME end-of-group cumulative total. The responder's explanation ("default gives both same-day rows the same cumulative total; add a transaction_id tiebreaker or pre-aggregate") is ACCURATE and a genuine value-add nuance.
- "window fns work like Postgres" — true for this construct.
- PARTITION BY tenant_id note for multi-tenant — CORRECT and prod-relevant.

## Q4 — accounts that NEVER sent a support ticket — 4.00 (Acc 3.75 / Clar 4.25 / App 4.0 / Comp 4.0)
LEAD CORRECT. `accounts a LEFT JOIN support_tickets t ON t.account_id=a.account_id WHERE t.ticket_id IS NULL` — textbook anti-join.
- NOT IN nullable-column 3VL trap (returns zero rows if the subquery yields any NULL) — CORRECTLY flagged; VERIFIED Trino uses null-aware anti-join semantics for NOT IN, matching the documented hazard.
- NOT EXISTS as an alternative — correct that it works.
- **UNSUPPORTED PERF CLAIM (ding):** "NOT EXISTS may be slightly slower internally due to how Trino's optimizer lowers correlated subqueries." VERIFIED via WebSearch: Trino **DECORRELATES** NOT EXISTS into an **anti-join**, typically producing a plan **EQUIVALENT** to LEFT JOIN/IS NULL — **not slower**. This is a loose/unsupported perf aside (mild false-mechanism-ish padding). RESOURCE-vs-SLIP = **RESPONDER SLIP / padding** — resources teach anti-join correctly; this is a volunteered unsupported aside, not a resource defect. Accuracy ding only; the lead + 3VL trap are correct.
- SELECT DISTINCT account_id subquery refinement — harmless.

---

## SCOPE NOTES
- **Q1 date_trunc verdict: returns TIMESTAMP (truncated to midnight), NOT DATE** — responder's "DATE value" is a minor type imprecision; grouping still correct.
- **Q3 default-frame verdict: default = RANGE UNBOUNDED PRECEDING; tied peers get the SAME (end-of-group) cumulative total** — responder's tied-dates explanation is CORRECT.
- **Q4 NOT EXISTS perf-claim verdict: Trino decorrelates NOT EXISTS into an anti-join, plan-EQUIVALENT to LEFT JOIN/IS NULL, NOT slower** — responder's "slightly slower" is UNSUPPORTED (responder padding slip, no resource defect).
- All 4 LEADS correct; defects are minor (Q1 type word, Q1/Q2 missing month-scope filter, Q4 unsupported perf aside).
- TICS CLEAN: no QUALIFY; semi-join naming is acceptable pattern-naming NOT false-mechanism mislabel; no MAX(varchar)-as-latest; no percent_rank inversion; no fabricated functions; no missing-CTE-column; no JOIN fan-out cross-product; no ts-minus-ts; no mid-churn. The Q4 unsupported-perf-claim is the only false-justification-family tic and is a one-off responder padding aside.

## RECOMMENDATION = DEFAULT NO-OP
Strong pass, margin +1.00. No resource defect, no findability gap. Re-probe candidates next sweep: (a) another running-total / cumulative-window Q (confirm ROWS-vs-RANGE tied-dates stays clean); (b) another anti-join "never did X" Q (watch whether the unsupported NOT-EXISTS-slower aside recurs — LIGHT defang ONLY if it recurs lead-level or 2-in-2 consecutive; one-off padding = re-probe-don't-churn per feedback_responder_broken_secondary_alternative.md). Federation r22 §13.x hard-locked NOT probed (OVERRIDDEN). NO resource edits. DO NOT bump training/state.json (already 974; passed=true preserved; final_iterations_remaining 0).
