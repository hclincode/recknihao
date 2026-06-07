# iter661 Judge Feedback — 2026-06-08 (EXTENDED PHASE)

**OVERALL: 4.875 PASS** (margin +1.375 above 3.5 floor; +0.65625 swing UP from iter660's 4.21875 — FIX-A landed cleanly on the month-name re-probe, no per-question avg below 3.5).

Per-Q: Q1=5.00 / Q2=4.75 / Q3=5.00 / Q4=4.75.

---

## Per-question scoring

### Q1 — Revenue by calendar MONTH NAME sorted Jan..Dec (FIX-A re-probe)
- **Responder query**: `SELECT CASE MONTH(order_date) WHEN 1 THEN 'January' ... WHEN 12 THEN 'December' END AS month_name, SUM(amount) AS total_revenue FROM orders GROUP BY MONTH(order_date) ORDER BY MONTH(order_date)`
- **Verification (Trino 467 docs trino.io/docs/467/sql/select.html, trino.io/docs/467/functions/datetime.html)**:
  - `month(x) -> bigint` confirmed in Trino 467 — returns month-of-year 1..12 from date/timestamp.
  - Docs rule: "When a GROUP BY clause is used in a SELECT statement all output expressions must be either aggregate functions or columns present in the GROUP BY clause." ORDER BY operates AFTER GROUP BY, so its expressions must resolve to GROUPING expressions, AGGREGATES, or output-column aliases/ordinals.
  - The responder's form: GROUP BY `MONTH(order_date)` (the sortable BIGINT number), CASE maps number->name in the SELECT projection, ORDER BY `MONTH(order_date)` which IS the grouping expression. **VALID Trino 467.**
- **FIX-A LANDED — EXPLICITLY CONFIRMED**. The iter660 Q2 bug was ORDER BY a raw ungrouped column wrapped in a function (`day_of_week(order_date)`) in a query grouped by the NAME expression — the analyzer looks through the wrapping and rejects the raw `order_date`. The responder's iter661 answer is **OPTION A** (the cleanest of the three valid options documented at r07:1350): GROUP BY the sortable number itself, project the name via CASE, ORDER BY the grouping expression. NO repeat of the iter660 ungrouped-column bug. The FIX-A note in resources/07-analytical-query-patterns.md ROUTED CORRECTLY for the month-name variant (keyword anchor "sort month name in calendar order" landed).
- **Scores**: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — avg **5.00**

### Q2 — Count NULLs in each of email/phone/billing_address in one query
- **Responder query**: `SUM(CASE WHEN email IS NULL THEN 1 ELSE 0 END) AS nulls_in_email, ... phone, ... billing_address FROM customers`
- **Verification**: Standard conditional aggregation. SUM-CASE per column in one pass returns each column's null count. `count_if(col IS NULL)` would be the cleaner Trino-native idiom (per Trino docs: `count_if(x)` equivalent to `count(CASE WHEN x THEN 1 END)`), and `count(*) FILTER (WHERE col IS NULL)` is another clean form — but SUM-CASE is fully valid and produces the correct result. Not penalized per the question instructions.
- **Scores**: Accuracy 5 / Completeness 4 / Clarity 5 / Actionability 5 — avg **4.75**
  - Completeness 4 (not 5): mentioning `count_if` would have been the bonus idiom callout, but answer is fully correct as-is.

### Q3 — Customer IDs in BOTH trial_signups AND paid_customers
- **Responder query**: `SELECT customer_id FROM trial_signups INTERSECT SELECT customer_id FROM paid_customers`
- **Verification (Trino 467 SELECT docs)**: INTERSECT returns rows in both result sets and deduplicates by default (INTERSECT ALL retains duplicates). Exactly the right operator for set-intersection of two columns. Valid Trino 467.
- **Scores**: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — avg **5.00**

### Q4 — Quantity-weighted average price
- **Responder query**: `SUM(unit_price * quantity) / SUM(quantity) AS weighted_avg_price FROM order_items`
- **Verification**: Mathematically correct weighted-average formula. NOT a flat AVG(unit_price) (which would be the wrong, unweighted answer). If both columns are DECIMAL or DOUBLE the division returns a decimal/double result; if both were INTEGER there would be integer division concerns, but unit_price is virtually always DECIMAL/DOUBLE in a real schema. A `* 1.0` or `CAST(... AS DOUBLE)` would bulletproof against an all-integer schema but is not required for typical price/quantity types. Acceptable as written.
- **Scores**: Accuracy 5 / Completeness 4 / Clarity 5 / Actionability 5 — avg **4.75**
  - Completeness 4 (not 5): a one-line caveat about integer division for all-integer schemas would have been the safety belt; correct enough for typical decimal prices.

---

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|----------|--------------|---------|---------------|-----|
| Q1 (month-name calendar order, FIX-A re-probe) | 5 | 5 | 5 | 5 | 5.00 |
| Q2 (NULL count per column) | 5 | 4 | 5 | 5 | 4.75 |
| Q3 (INTERSECT) | 5 | 5 | 5 | 5 | 5.00 |
| Q4 (weighted avg price) | 5 | 4 | 5 | 5 | 4.75 |

**Overall average: 4.875 / 5 — PASS** (threshold 3.5). No per-question avg below 3.5.

---

## FIX-A landed verdict — EXPLICIT

The iter661 FIX-A (ORDER-BY-validity-in-a-GROUP-BY-query block inserted at r07:1350) **LANDED CLEANLY** for the month-name re-probe. The responder chose **OPTION A** (group by the sortable number `MONTH(order_date)`, project the name via CASE in SELECT, ORDER BY the same `MONTH(order_date)` grouping expression). This is the DOCS-CORRECT form per trino.io/docs/467/sql/select.html — the ORDER BY expression IS a grouping expression, NOT a raw ungrouped column. The iter660 Q2 silent-wrong bug (ORDER BY `day_of_week(order_date)` while grouping by `format_datetime(...,'EEEE')` — function-wrapping does NOT save the bare `order_date`) was NOT repeated. The keyword anchors "sort month name in calendar order" and "ORDER BY in a GROUP BY query" routed the responder to the right canonical.

---

## iter662 recommendation

**DEFAULT NO-OP / durability-breadth.** All four answers pass cleanly; no per-question average below 3.5; no FIX needed. FIX-A is now demonstrated to land for BOTH the weekday-name variant (iter660 Q2 was the bug, canonical inserted, would now pass) AND the month-name variant (iter661 Q1 PASSED at 5.0). The FIX-A canonical at r07:1350 is durable and routes correctly for both date-name-vs-chronological-sort variants.

For iter662, probe **adjacent / orthogonal angles** that have not been re-tested recently:
- Q1 candidate: revenue by **quarter name** ('Q1','Q2','Q3','Q4') sorted Q1..Q4 — exercises the same OPTION-A pattern with `quarter(order_date)` as the sort key. Confirms the FIX-A block generalizes beyond month/weekday.
- Q2 candidate: a `count_if(col IS NULL)` re-probe — confirms the responder also finds the Trino-native cleaner idiom, not only SUM-CASE.
- Q3 candidate: EXCEPT (rows in A but NOT in B) — sibling of INTERSECT, exercises the same set-operator routing.
- Q4 candidate: weighted average with an INTEGER-only schema callout — exercises the integer-division safety-belt the responder did not mention.

Recommend prioritizing the **quarter-name FIX-A generalization re-probe** to confirm the canonical's keyword anchors cover the broader date-bucket-name-chronological-sort family, not just month/weekday.
