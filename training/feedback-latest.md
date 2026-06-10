# Judge Feedback — iter906 (NO-OP durability sweep)

**Overall: 4.58 / 5.00 — PASS** (per-Q 4.9375/3.375/5.00/5.00 = 18.3125/4 = 4.578). Overall average governs; no per-Q veto. Margin +1.08 over the 3.5 threshold.

**Verdict: iter907 = re-probe-don't-churn on the Q2 first query (RESPONDER SYNTHESIS MUDDLE, resources correct).** Three of four answers dialect-clean vs Trino 467; the Q2 FIRST query is broken but the CORRECT clean 2nd query IS delivered and even labeled "simpler." Teacher: ZERO edits. Do NOT touch state.json (already passed).

All dialect facts VERIFIED vs trino.io/docs/467 (select/window .html) + Trino error-message family via WebFetch/WebSearch 2026-06-10. iter882 verify-first applied: the Q2 first query was verified against the GROUP-BY + window-evaluation-order rule BEFORE judging, and the three clean queries (Q1/Q3 ROW_NUMBER-nesting, Q4 MAX OVER + NULLIF) were verified correct and NOT flagged.

---

## Per-question scores (Accuracy / Completeness / Clarity / Actionability)

### Q1 — flag the single cheapest line item per order — 4.9375 (5 / 5 / 4.75 / 5)
Subquery `ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY price ASC) AS rn`, then outer `WHERE rn = 1` (or keep all rows + `CASE WHEN rn = 1 THEN true ELSE false END` flag). CORRECT and valid in Trino 467.

VERIFIED window.html: window functions evaluate after HAVING but before ORDER BY (i.e. after WHERE), so a ROW_NUMBER reference cannot go in WHERE directly — nesting in a subquery/CTE then filtering the materialized `rn` column in the OUTER query is the required form (Trino 467 has NO QUALIFY — confirmed via WebSearch). `WHERE rn = 1` filters a REAL inner column (legal). `ROW_NUMBER ... ORDER BY price ASC` correctly assigns 1 to the single cheapest line item per order; both the filter mode (one row per order) and the flag mode (keep all rows, mark the cheapest) are correctly distinguished.

Tiny clarity nuance (NOT a defect, weighed proportionally → Clar 4.75): the shown query carries BOTH `WHERE rn = 1` AND the `CASE WHEN rn = 1 ...` flag, which is slightly redundant if presented as one statement — but the responder explains both modes, so this reads as "here are two ways," not an error. No accuracy deduction.

### Q2 — boolean per customer: lifetime spend >= \$1000 — 3.375 (3.0 / 4.0 / 3.0 / 3.5)
**Q2 FIRST-QUERY VERDICT: CONFIRMED DEFECT — the window-over-grouped-column form is INVALID in Trino 467.** Partial credit, not zero, because the CORRECT clean 2nd query IS delivered and even labeled "simpler."

FIRST query (muddled / invalid):
```
SELECT customer_id, CASE WHEN total_spend >= 1000 THEN true ELSE false END
FROM (
  SELECT customer_id, SUM(order_value) OVER (PARTITION BY customer_id) AS total_spend
  FROM orders GROUP BY customer_id
)
GROUP BY customer_id, total_spend
```
The inner query has `GROUP BY customer_id`. VERIFIED vs trino.io/docs/467 select.html: "When a GROUP BY clause is used in a SELECT statement all output expressions must be either aggregate functions or columns present in the GROUP BY clause." Window functions evaluate AFTER GROUP BY (window.html: after HAVING, before ORDER BY), so `SUM(order_value) OVER (PARTITION BY customer_id)` operates on the post-GROUP-BY result set — and there `order_value` is NEITHER a grouped column NOR an aggregate. Trino's analyzer rejects this with the "must be an aggregate expression or appear in GROUP BY clause" / "must be aggregated or appear in GROUP BY clause" error family (confirmed via WebSearch). The inner query is therefore UNRUNNABLE. (Even if it parsed, mixing a window aggregate with a GROUP BY and then re-grouping on `total_spend` is conceptually muddled — windowed SUM and grouped SUM are different shapes.)

SECOND query (clean / correct):
```
SELECT customer_id, SUM(order_value) AS lifetime_spend, SUM(order_value) >= 1000 AS crossed_1000
FROM orders GROUP BY customer_id
```
CORRECT — plain `SUM(order_value)` grouped by `customer_id` + boolean comparison `SUM(order_value) >= 1000` projected directly as a boolean column. Valid in Trino 467 (a comparison on an aggregate in the SELECT list is legal; a window function is not even needed for a per-customer scalar). This is the right, minimal answer and the responder explicitly flagged it as "simpler."

Scoring: Acc 3.0 (the lead query is unrunnable; the second is correct), Comp 4.0 (the question IS fully answered by the clean 2nd query), Clar 3.0 (leading with a broken, over-complicated query muddles the explanation for a non-expert), Act 3.5 (a non-expert who copies the FIRST query hits an analyzer error; the labeled-"simpler" 2nd query rescues actionability).

### Q3 — second-earliest signup date per company — 5.0 (5 / 5 / 5 / 5)
Subquery `ROW_NUMBER() OVER (PARTITION BY company_id ORDER BY created_at ASC) AS rn`, then outer `WHERE rn = 2`. CORRECT and valid in Trino 467.

VERIFIED window.html: row_number assigns a unique sequential number starting at 1 per partition; `ORDER BY created_at ASC` orders earliest-first, so rn=2 is the second-earliest signup per company. Nesting + outer-`WHERE rn = 2` on a REAL materialized column is the required form (no QUALIFY in 467). Ties at the earliest timestamp resolve arbitrarily (row_number is non-deterministic across equal sort keys) — a minor nuance, NOT a defect (the question does not specify tie handling; an explicit tiebreaker like `ORDER BY created_at ASC, company_record_id` would make it deterministic if needed).

### Q4 — each order's share vs that customer's biggest order — 5.0 (5 / 5 / 5 / 5)
`ROUND(order_value / MAX(order_value) OVER (PARTITION BY customer_id), 2) AS share_of_biggest`, plus the div-by-zero guard `NULLIF(MAX(order_value) OVER (PARTITION BY customer_id), 0)`. CORRECT and valid in Trino 467.

VERIFIED window.html: all aggregates (incl. MAX) usable as window functions via OVER, so `MAX(order_value) OVER (PARTITION BY customer_id)` broadcasts each customer's largest order onto every one of that customer's rows; `order_value / that-max` = share-of-customer-max, ROUND(,2) to 2 dp. The `NULLIF(max, 0)` guard is apt: NULLIF returns NULL when the max is 0, turning a would-be DIVISION_BY_ZERO into a NULL result (note — for DOUBLE/REAL operands division by zero yields Infinity per IEEE-754 rather than throwing, but for DECIMAL/INTEGER it throws, so the NULLIF guard is the safe, dialect-correct choice regardless of column type). A thoughtful, footgun-anticipating answer.

---

## SCOPE CHECK — is the Q2 first-query defect a resource gap or a responder synthesis muddle?

**RESPONDER SYNTHESIS MUDDLE — NOT a resource gap.** The responder DID produce the correct, minimal `SUM(order_value) >= 1000` GROUP BY query (the 2nd query) and even labeled it "simpler," demonstrating the resources teach the right pattern. The defect is that the responder ALSO synthesized an unnecessary, invalid window-over-grouped-column lead query — a synthesis slip, not a missing/incorrect resource. The GROUP-BY-output-must-be-grouped-or-aggregate rule and the window-evaluate-after-GROUP-BY rule are already taught correctly (and the responder's own 2nd query proves the simple GROUP BY form is well-internalized). A FIX-A "wrong card" would only duplicate existing pins and risks the defang-backfire pattern (banned-form snippet getting copied).

**iter907 = re-probe-don't-churn.** Re-probe a fresh phrasing of "per-customer boolean / scalar threshold (e.g. lifetime spend >= X)" next sweep to confirm the muddle is a one-off and that the responder reliably reaches for the plain GROUP BY + boolean-comparison form (not a needless window function). Do NOT add a "wrong" card; do NOT churn any GROUP-BY / window-evaluation-order pin.

---

## Teacher action: ZERO edits (NO-OP confirmed for the resource layer)

- Do NOT add any "wrong" card for Q1–Q4.
- Do NOT mark the Q1 ROW_NUMBER-subquery + outer-WHERE-rn=1 form wrong (correct), the Q3 rn=2 second-earliest form wrong (correct), or the Q4 MAX() OVER + NULLIF share form wrong (correct).
- Do NOT mark the Q2 SECOND query (`SUM(order_value) >= 1000` GROUP BY) wrong — it is the correct, idiomatic answer.
- The ONLY defect is the Q2 FIRST query (window-over-grouped-column) — a responder synthesis muddle, handled by an iter907 re-probe, NOT a resource edit.
- Federation (4.49944/310) remains the only un-passed row — bulletproofed angles only; NO federation edits.
- Do NOT touch any iter534–905 pin. PIN Trino 467. DO NOT bump training/state.json (already passed; overall 4.58 PASS holds).
