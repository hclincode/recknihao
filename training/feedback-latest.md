# Iter662 Judge Feedback — 2026-06-08 (EXTENDED PHASE)

**OVERALL: 5.000 STRONG PASS** (margin +1.500 above 3.5 floor; +0.125 swing UP from iter661's 4.875 — FIX-A generalization to quarter landed perfectly, all four answers textbook-clean).

Per-Q: Q1=5.00 / Q2=5.00 / Q3=5.00 / Q4=5.00.

---

## Per-question scores

### Q1 — Revenue by quarter labeled Q1..Q4 in calendar order (FIX-A generalization re-probe)

**Answer**: `SELECT quarter(order_date) AS q, CASE quarter(order_date) WHEN 1 THEN 'Q1' WHEN 2 THEN 'Q2' WHEN 3 THEN 'Q3' WHEN 4 THEN 'Q4' END AS quarter_label, SUM(amount) AS total_revenue FROM orders GROUP BY quarter(order_date) ORDER BY quarter(order_date)`

| Dimension | Score | Notes |
|---|---|---|
| Accuracy | 5 | Verified vs trino.io/docs/467/functions/datetime.html: `quarter(x)` returns bigint 1..4. Verified vs trino.io/docs/467/sql/select.html: ORDER BY a grouping expression is valid. `quarter(order_date)` IS in the GROUP BY → using it in ORDER BY is the OPTION-A form documented at r07:1351. CASE maps number→label cleanly. Calendar order preserved (1<2<3<4 maps to Q1<Q2<Q3<Q4). |
| Completeness | 5 | All three required pieces present: numeric quarter, label, revenue. Sort-by-calendar-order requirement satisfied. |
| Clarity | 5 | Single clean statement, alias names are intuitive. |
| Actionability | 5 | Engineer can paste-and-run. |
| **Avg** | **5.00** | |

**FIX-A GENERALIZATION CHECK — CONFIRMED PASS (KEY CHECK).** The iter661 FIX-A (ORDER-BY-in-grouped output for label-mapped categories) has now generalized cleanly across THREE entity framings:
1. weekday-name (iter660 FAIL → iter661 fixed via OPTION-A at r07:1351)
2. month-name (iter661)
3. quarter (iter662 — this answer)

The responder picked OPTION-A (group-by-the-number, CASE in SELECT, ORDER BY the grouping expression) without prompting. This is the **3rd successful generalization** of the FIX-A primitive and confirms the iter661 lock is durable across the calendar-label class. Crucially this is NOT the iter660 ORDER-BY-ungrouped bug — `quarter(order_date)` appears in BOTH the GROUP BY and the ORDER BY, satisfying the Trino 467 SELECT-clause rule.

### Q2 — Customers in trial_signups but NOT in paid_customers

**Answer**: PRIMARY = `NOT EXISTS` anti-join; ALT = `LEFT JOIN ... WHERE pc.customer_id IS NULL` with SELECT DISTINCT; noted NOT EXISTS is safer than NOT IN with NULLs.

| Dimension | Score | Notes |
|---|---|---|
| Accuracy | 5 | Both anti-join forms are correct in Trino 467. NOT EXISTS correlated subquery is the canonical anti-join and handles NULLs cleanly. LEFT JOIN ... IS NULL is the equivalent join-form. The NULL warning on NOT IN is the correct and important caveat. |
| Completeness | 5 | Primary + alternative + NULL safety note. The run anticipated EXCEPT, but anti-join is equally valid (EXCEPT auto-dedups both sides; anti-join is more flexible when only one side should dedup) — no penalty per directive. |
| Clarity | 5 | Clean, names two idiomatic patterns. |
| Actionability | 5 | Drop-in for either pattern preference. |
| **Avg** | **5.00** | |

### Q3 — Single busiest hour-of-day by event count

**Answer**: `SELECT EXTRACT(HOUR FROM created_at) AS hour_of_day, COUNT(*) AS event_count FROM events GROUP BY EXTRACT(HOUR FROM created_at) ORDER BY event_count DESC LIMIT 1`

| Dimension | Score | Notes |
|---|---|---|
| Accuracy | 5 | Verified vs trino.io/docs/467/functions/datetime.html: EXTRACT(HOUR FROM ts) is valid and returns 0..23. ORDER BY on an output alias (`event_count`) is valid in Trino 467 (distinct from ORDER BY an ungrouped column — output aliases are explicitly permitted). LIMIT 1 returns the single top row. |
| Completeness | 5 | Hour bucket + count + sort + cap = full answer. |
| Clarity | 5 | One statement, idiomatic. |
| Actionability | 5 | Direct paste. |
| **Avg** | **5.00** | |

### Q4 — Customers with > 3 failed payments

**Answer**: `SELECT customer_id FROM payments WHERE status = 'failed' GROUP BY customer_id HAVING COUNT(*) > 3`

| Dimension | Score | Notes |
|---|---|---|
| Accuracy | 5 | WHERE pre-filters to failed rows before grouping (efficient), GROUP BY customer, HAVING COUNT(*) > 3 keeps customers with strictly more than 3 failures. `>` is strict (4+), which matches "more than 3". An equivalent form `HAVING count_if(status='failed') > 3` without the WHERE is also valid but unnecessary here. |
| Completeness | 5 | Fully addresses the question. |
| Clarity | 5 | Textbook clean. |
| Actionability | 5 | Direct paste. |
| **Avg** | **5.00** | |

---

## Overall scorecard

| | Accuracy | Completeness | Clarity | Actionability |
|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 |
| Q2 | 5 | 5 | 5 | 5 |
| Q3 | 5 | 5 | 5 | 5 |
| Q4 | 5 | 5 | 5 | 5 |

**Overall average: 5.000 / 5 — STRONG PASS**

No per-Q average below 3.5 → no iter663 FIX-A required.

## Iter663 recommendation

**DEFAULT NO-OP / DURABILITY-BREADTH.** All four answers are textbook-clean. The key finding of iter662 is positive durability evidence:

- **FIX-A (iter661 r07:1351 ORDER-BY-in-grouped-output) has now generalized to THREE entity framings without regression**: weekday-name (iter661), month-name (iter661), quarter (iter662). The OPTION-A primitive (group-by-the-number + CASE-in-SELECT + ORDER-BY-the-grouping-expression) is being recalled and composed correctly across calendar-bucket variants.
- Anti-join (NOT EXISTS / LEFT JOIN IS NULL) recall is clean — the responder volunteered both forms AND the NULL safety note unprompted.
- EXTRACT + ORDER-BY-alias + LIMIT 1 composition is clean.
- WHERE + GROUP BY + HAVING COUNT(*) > N is textbook.

Teacher should make **zero edits** for iter663. Continue probing durability-breadth on adjacent calendar-label angles to harden the FIX-A generalization further (e.g. month-name fiscal-year offset, day-of-week with custom Mon-first ordering, year-quarter combined label like '2025-Q1') — these are stress tests, not gaps.

## Locks to preserve

- iter661 FIX-A at r07:1351 (ORDER-BY-validity-in-GROUP-BY with OPTIONs A/B/C) — confirmed generalizing cleanly to quarter.
- r23:732 LEADING CANONICAL count_if (not needed this iter but available).
- r23:853 EXCEPT / r23:873 EXCEPT-dedup-semantic + cross-link to anti-join.
- r23:1179 EXTRACT field list including HOUR.
- resources/22 federation HARD LOCK (last touched iter448 c2627a8) — UNTOUCHED.
