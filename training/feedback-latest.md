# Judge Feedback — Iter 909 (EXTENDED PHASE, durability sweep)

**Overall: 4.094 PASS** (per-Q 2.75 / 4.5 / 4.125 / 5.00 = 16.375 / 4 = 4.094; margin +0.594; OVERALL AVERAGE governs — no per-Q veto). Federation NOT probed (4.49944/310 row UNCHANGED). **1 confirmed Q1 DIALECT DEFECT (broken GROUP BY, responder synthesis muddle) + 1 Q3 prose-mechanism mischaracterization on otherwise-correct SQL. Both → re-probe-don't-churn (resources correct). Teacher ZERO edits.**

All facts VERIFIED vs trino.io/docs/467 (aggregate/datetime/select/comparison .html) + Trino 467 git-tag source (DateTimeFunctions.java / Joda DurationField) + WebSearch 2026-06-10. iter882 verify-first applied in BOTH directions (did not bless a doc-wrong claim, did not flag a doc-correct one).

---

## Q1 — top-10 customers' revenue as % of total (one number) — 2.75 (DEFECT, partial credit)

**VERDICT: BROKEN as written — CONFIRMED on BOTH counts.** The query:
```
SELECT ROUND(100.0 * SUM(CASE WHEN customer_rank <= 10 THEN order_value ELSE 0 END) / SUM(order_value), 2) AS top_10_revenue_pct
FROM (SELECT customer_id, order_value, ROW_NUMBER() OVER (ORDER BY SUM(order_value) DESC) AS customer_rank
      FROM orders GROUP BY customer_id)
GROUP BY 1
```
**(a) INNER query INVALID.** `SELECT customer_id, order_value, ROW_NUMBER() OVER (ORDER BY SUM(order_value) DESC) ... FROM orders GROUP BY customer_id`: the bare `order_value` in the SELECT list is NEITHER in GROUP BY NOR wrapped in an aggregate → Trino 467 rejects with `'order_value' must be an aggregate expression or appear in GROUP BY clause` (VERIFIED select.html GROUP-BY-output rule, pinned across 13 resource files). The `ROW_NUMBER() OVER (ORDER BY SUM(order_value) DESC)` part is itself fine (SUM is an aggregate, legal in a windowed ORDER BY over a grouped set) — the defect is the bare `order_value` projection.

**(b) OUTER `GROUP BY 1` INVALID.** `GROUP BY 1` groups by the first output column, which is the `ROUND(...)` aggregate expression — grouping by an aggregate is rejected. The outer query is a single scalar aggregate and needs NO GROUP BY at all.

**Correct form** (intent is right — rank customers by total spend, take top-10 share):
```
SELECT ROUND(100.0 * SUM(CASE WHEN customer_rank <= 10 THEN total_spend ELSE 0 END) / SUM(total_spend), 2) AS top_10_revenue_pct
FROM (SELECT customer_id, SUM(order_value) AS total_spend,
             ROW_NUMBER() OVER (ORDER BY SUM(order_value) DESC) AS customer_rank
      FROM orders GROUP BY customer_id)
```
(inner aggregates `order_value` into `total_spend`; outer has no GROUP BY).

**Score:** Acc 2.0 (unrunnable, two errors) / Comp 3.5 (approach delivered, intent correct) / Clar 3.0 / Act 2.5 (non-expert copies → analyzer error) = **2.75**. Partial credit not zero — the ranking approach is sound.

**SCOPE CHECK → RESPONDER SYNTHESIS MUDDLE, NOT a resource gap.** The GROUP-BY-output rule ("must be aggregate or in GROUP BY") is taught in 13 resource files; rank-by-aggregate + top-N-share patterns are pinned in r07/r23/r27 (183 occurrences of ROW_NUMBER/top-N/rank). The responder simply forgot to aggregate `order_value` in the inner query and bolted on a needless `GROUP BY 1`. A FIX-A "wrong card" would duplicate existing pins and risk defang-backfire. **NO resource edit. Re-probe "top-N entities' share of a total (rank by an aggregate, take share)" with fresh phrasing next sweep to confirm one-off.**

---

## Q2 — per-order yes/no whether EVERY line item shipped — 4.5

**VERDICT: min(boolean) IS VALID — answer CORRECT (if non-idiomatic). bool_and/every is the cleaner idiom (completeness nuance, NOT a defect).** `CASE WHEN MIN(shipped) = true THEN 'yes' ELSE 'no' END ... GROUP BY order_id`: VERIFIED aggregate.html + WebSearch 2026-06-10 — boolean IS orderable in Trino 467 (`TRUE > FALSE`), so `min(shipped)` is accepted and returns `false` iff any input is false, else `true`. The responder's logic is exactly right.

**Completeness nuance (the deduction):** Trino 467 has the purpose-built `bool_and(shipped)` (returns true iff every input true) and its alias `every(shipped)` — the idiomatic "all shipped" test (VERIFIED aggregate.html). `CASE WHEN bool_and(shipped) THEN 'yes' ELSE 'no' END` is the cleaner one-liner. The responder's min(boolean) form is fully correct but did not mention the idiom.

Edge nuances correctly implicit: LEFT-JOIN variant → order with zero line items → MIN(NULL)=NULL → 'no'; a line item with shipped=NULL is skipped by MIN (minor, not scored as a defect).

**Score:** Acc 5.0 (min(boolean) valid + correct) / Comp 4.0 (missed bool_and/every idiom) / Clar 4.5 / Act 4.5 = **4.5**.

---

## Q3 — whole hours between placed_at and shipped_at (2h45m → 2) — 4.125

**VERDICT: SQL `date_diff('hour', placed_at, shipped_at)` is CORRECT for the question's "whole duration hours" intent — Trino 467 uses TRUNCATED-ELAPSED (interpretation A), NOT boundary-crossing.** VERIFIED via Trino 467 git-tag DateTimeFunctions.java (date_diff delegates to Joda field difference) + Joda DurationField.getDifferenceAsLong: for FIXED-duration fields (hour/minute/second) the difference is integer division of the millisecond delta by the unit's fixed duration with fractional units DROPPED (truncated toward zero). So a 2h45m gap ALWAYS = 2 regardless of minute alignment — exactly the question's "2h45m → 2" requirement. (Calendar-boundary semantics apply only to VARIABLE-duration fields month/year per pinned reference_trino_datediff_dayaware; hour is fixed-duration = pure elapsed division.) Docs example `date_diff('hour', '2020-03-01 00:00', '2020-03-02 00:00') = 24` is consistent.

**Accuracy/clarity nuance (the deduction):** the responder's PROSE — "returns the number of complete hour boundaries crossed" and the "2:15 PM to 5:45 PM returns 3" gloss — MISCHARACTERIZES the mechanism. The actual mechanism is truncated elapsed (floor of total seconds / 3600), NOT field-boundary counting. (The 2:15→5:45 number, 3, happens to be right because that gap is 3h30m → floor = 3 — coincidence of magnitude, not vindication of the "boundaries crossed" model. The "boundaries crossed" framing would give a WRONG mental model for a 2h45m gap aligned across an hour boundary.) The SQL is right; the explanation of WHY is wrong.

**Score:** Acc 4.0 (correct SQL, wrong mechanism prose) / Comp 4.5 / Clar 3.5 (mischaracterized mechanism could mislead) / Act 4.5 = **4.125**.

**SCOPE CHECK → re-probe-don't-churn.** date_diff truncated-elapsed/day-aware semantics are pinned (reference_trino_datediff_dayaware). This is a responder prose slip on correct SQL, not a resource gap. NO edit. Optionally, if it touches NO pin, a 1-line "date_diff('hour') = truncated elapsed (floor seconds/3600), NOT hour-boundary count" near a date_diff card — SKIP if it churns the day-aware pin.

---

## Q4 — repeat-purchase flag (1st order 'no', 2nd+ 'yes') — 5.00

**VERDICT: CLEAN & CORRECT.** `SELECT order_id, customer_id, order_date, CASE WHEN ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date) = 1 THEN 'no' ELSE 'yes' END AS is_repeat_purchase FROM orders`: VERIFIED select.html + window.html — a window function in a CASE in the SELECT list is legal (windows evaluate in SELECT/ORDER BY context); ROW_NUMBER PARTITION BY customer_id ORDER BY order_date assigns 1 to each customer's earliest order → 'no', 2+ → 'yes'. Correctly flags first vs repeat. No window-fn-in-WHERE, no GROUP-BY muddle.

**Score:** Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0 = **5.00**.

---

## Directive for iter910

- **DEFAULT NO-OP / re-probe-don't-churn. Teacher ZERO edits.** Both issues are responder slips on top of correct, well-taught resources:
  - Q1 broken GROUP BY = synthesis muddle (forgot to aggregate inner `order_value`, added needless `GROUP BY 1`); GROUP-BY-output rule + rank-by-aggregate/top-N-share patterns already pinned across 13 files + r07/r23/r27. **Do NOT add a "wrong" card** (duplicates pins, defang-backfire risk).
  - Q3 = correct SQL with wrong mechanism prose; date_diff truncated-elapsed is pinned. **Do NOT churn the date_diff day-aware pin.**
- **Do NOT mark wrong:** Q2 min(boolean) (VALID), Q3 date_diff('hour') SQL (CORRECT — truncated elapsed), Q4 ROW_NUMBER-in-CASE (CORRECT). Q1's APPROACH (rank by total spend, top-10 share) is correct — only the SQL execution is broken.
- **Re-probe next sweep (fresh adjacents):** (1) "top-N entities' share of a total" to confirm the responder reaches the aggregate-in-inner + no-outer-GROUP-BY form (Q1 one-off check); (2) "all/every X true" to confirm bool_and/every idiom uptake; (3) a date_diff('hour') minute-misaligned case to confirm truncated-elapsed prose.
- Federation (4.49944/310) remains the only un-passed row — bulletproofed angles only.
- Do NOT touch any iter534–908 pin. PIN Trino 467. NO federation edits. **DO NOT bump training/state.json** (already passed; overall 4.094 PASS holds).
