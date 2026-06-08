# Judge Feedback — iter763 (EXTENDED PHASE)

**Overall: 4.5625 PASS** (per-Q 3.25 / 5.00 / 5.00 / 5.00 = 18.25 / 4; margin +1.0625; overall avg governs, no per-Q veto).

Federation (r22) NOT probed. All dialect claims verified against trino.io/docs/467 (sql/select.html, functions/math.html, functions/aggregate.html).

---

## Q1 — ROLLUP-on-date-parts RE-PROBE — avg 3.25 (Acc 2 / Comp 4 / Clar 4 / Act 3)

**Structural ROLLUP-on-EXPRESSION fix: LANDED / CLOSED.** The responder pre-computed `EXTRACT(YEAR …) AS yr, EXTRACT(MONTH …) AS mo` into named columns in a CTE and then did `GROUP BY ROLLUP(yr, mo)` over the **names** — NOT `ROLLUP(EXTRACT(...), EXTRACT(...))`. This is exactly the routing the iter762 FIX-A targeted. The column-names-only structural defect did not recur. The GROUPING() CASE bitmask (0=detail, 1=year_subtotal, 3=grand_total, correctly no WHEN-2 branch) and `ORDER BY yr, mo` are docs-correct.

**BUT a SEPARATE, NEW defect surfaced — the outer query does NOT compile.** The CTE already pre-aggregates: `SELECT … SUM(amount) AS total_amount … GROUP BY yr, mo`. The outer then does `SELECT yr, mo, total_amount FROM date_parts GROUP BY ROLLUP(yr, mo)` — `total_amount` is neither in the outer GROUP BY nor wrapped in an aggregate. **VERIFIED against sql/select.html: "When a GROUP BY clause is used in a SELECT statement all output expressions must be either aggregate functions or columns present in the GROUP BY clause."** The query fails analysis ("must be an aggregate expression or appear in GROUP BY"). Accuracy scored down to 2 for a non-compiling answer.

**This is a RESPONDER SYNTHESIS-SLIP, NOT a resource defect.** The r28 canonical (resources/28, lines 444–453) is CORRECT: the CTE computes the **parts only** (`SELECT EXTRACT(YEAR …) AS yr, EXTRACT(MONTH …) AS mo, revenue FROM subscriptions`) and the **outer** does `SELECT yr, mo, SUM(revenue) AS total FROM r GROUP BY ROLLUP(yr, mo)`. The responder garbled it by hoisting the `SUM` into the CTE (pre-aggregating `GROUP BY yr, mo`) and then failing to re-aggregate `total_amount` in the outer. The canonical models the correct one-SUM-in-the-outer shape; the responder did not follow it.

**iter764 designation: this is NOT a FIX-A on the r28 ROLLUP canonical (it is already correct and unambiguous).** The structural ROLLUP-on-expression issue is CLOSED. However, because the responder demonstrably mis-routed the aggregation (pre-aggregated in the CTE then referenced the alias unaggregated under ROLLUP), iter764 should be a **MINOR findability/inoculation nudge**: add a short defang adjacent to the r28 CTE-then-ROLLUP canonical making the SUM-placement explicit — e.g. "The CTE computes the date PARTS only (no aggregation); the OUTER query does the `SUM(...)` + `ROLLUP`. Do NOT pre-aggregate (`SUM … GROUP BY yr, mo`) in the CTE and then `SELECT total … GROUP BY ROLLUP(yr, mo)` — a pre-aggregated column referenced under the outer ROLLUP that is neither grouped nor re-aggregated fails analysis. If you DO pre-aggregate in the CTE, the outer must `SUM(total_amount)`." ADDITIVE only; must NOT churn the iter761 selection-router, the iter762 column-names-only clarifier, or the CUBE/GROUPING-SETS/bitmask content.

## Q2 — round-to-nearest-nickel — avg 5.00 (5/5/5/5) — CLEAN

`ROUND(price * 20.0) / 20.0` snaps to the nearest 0.05. VERIFIED arithmetically on every example: 4.92*20=98.4→98→4.90; 0.08*20=1.6→2→0.10; 4.87*20=97.4→97→4.85. Trino `round(x)` returns x rounded to the nearest integer (HALF_UP / round-half-away-from-zero); none of the example values land on an exact half-integer tie, so the half-tie mode is immaterial to correctness here. Equivalent to `round(price/0.05)*0.05`. Correctly distinct from round-to-2-decimals. Clean.

## Q3 — top-3-per-category by revenue — avg 5.00 (5/5/5/5) — CLEAN

`ROW_NUMBER() OVER (PARTITION BY category ORDER BY revenue DESC)` in a subquery/CTE with outer `WHERE rn <= 3` is the canonical Trino 467 top-N-per-group idiom (QUALIFY is NOT Trino, correctly avoided). ROW_NUMBER yields exactly 3 even under ties — a valid reading of "top 3"; RANK/DENSE_RANK would include ties. Clean.

## Q4 — whole-row argmax per customer — avg 5.00 (5/5/5/5) — CLEAN

Both forms valid Trino 467: (a) `max_by(order_id, amount)`, `max_by(order_date, amount)`, `MAX(amount)` GROUP BY customer — VERIFIED aggregate.html "max_by(x, y) returns the value of x associated with the maximum value of y"; one max_by per carried column is the correct multi-column argmax. (b) `ROW_NUMBER() OVER (PARTITION BY customer ORDER BY amount DESC)` with outer `WHERE rn = 1`. Clean.

---

## Verdict

- **ROLLUP-on-EXPRESSION structural issue: CLOSED.** The iter762 FIX-A worked on the 1st re-probe — named-col routing through a CTE landed. Pin holds: ROLLUP/CUBE/GROUPING SETS take COLUMN NAMES only.
- **Q1 outer-aggregation slip: RESPONDER SYNTHESIS-SLIP, not a resource defect.** The r28 canonical is correct (CTE = parts only, outer = SUM + ROLLUP). The responder mangled the SUM placement on its own.
- **Q2 / Q3 / Q4: all CLEAN, max signal.**
- **iter764 designation: MINOR FIX-A (inoculation nudge only)** — add a SUM-placement defang adjacent to the existing r28 CTE-then-ROLLUP canonical so the synthesis-slip does not recur; do NOT rewrite the canonical, do NOT churn the selection-router / column-names clarifier / CUBE-GROUPING-SETS-bitmask content. HOLD all iter534–762 locks. Federation r22 untouched. DO NOT bump training/state.json (already 763).
