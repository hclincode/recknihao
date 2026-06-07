# Iter 639 — Judge Feedback (EXTENDED PHASE)

**Overall: 4.21875 PASS** (margin +0.71875 above 3.5 floor; -0.25 swing from iter638's 4.46875).
Per-Q averages: Q1 = 5.0, Q2 = 3.0, Q3 = 3.875, Q4 = 5.0. Governing label = PASS (overall avg 4.21875 >= 3.5; no per-Q gate override per directive). Q2 (3.0 < 3.5) flagged separately as iter640 FIX-A candidate.

Federation NOT probed this iteration. The 4.49944/310 row remains UNCHANGED.

---

## Q1 — roll up INTEGER invoice_number into sorted comma-separated string (FIX-A VALIDATION)

`array_join(array_agg(CAST(invoice_number AS varchar) ORDER BY invoice_number), ', ') GROUP BY account_id`. CAST is mandatory (listagg/array_join are VARCHAR-only; Trino has no implicit numeric->varchar coercion). ORDER BY inside array_agg references the numeric column so sort is numeric, not lexicographic.

**iter639 FIX-A VALIDATION — LANDED CLEAN.** Responder CAST the integer to varchar inside array_agg (no bare `array_join(array_agg(invoice_number ...), ...)` over array(integer), no bare `listagg(invoice_number, ', ')` over integer). The varchar-CAST guardrail at r07:§1a.2A sub-canonical reached the responder on first probe.

Verified against trino.io/docs/467/functions/aggregate.html (listagg requires varchar input), functions/array.html (array_join signature `array_join(array(varchar), varchar) -> varchar`), functions/conversion.html ("Trino will not convert between character and numeric types"). CAST-inside-array_agg pattern is the docs-preferred one-step form. ORDER BY inside array_agg with the underlying numeric column yields numeric ordering (1, 2, 10, 100, not '1','10','100','2').

| Dim | Score | Reason |
|---|---|---|
| Accuracy | 5.0 | Valid Trino 467; CAST is the correct fix; numeric ORDER BY semantics correct. |
| Completeness | 5.0 | Explicit MANDATORY-CAST callout + numeric-vs-lex sort distinction + both string-rollup forms covered. |
| Clarity | 5.0 | Beginner-clear; the "why" of CAST is articulated as a Trino-specific coercion rule. |
| Actionability | 5.0 | Engineer can copy-paste; the trap (bare listagg/array_join over numeric) is named. |
| **Per-Q avg** | **5.0** | |

---

## Q2 — per product: THIS YEAR'S TOTAL revenue / LAST YEAR'S TOTAL revenue (annual YoY ratio per product)

Answer gave a `monthly_revenue` CTE (SUM by product + month_trunc) + LEFT JOIN to prev year on `date_add('month',-12,cur.month)` + `WHERE cur.month = date_trunc('month', current_date)`, returning `cur.monthly_revenue / prev.monthly_revenue`.

**TARGET-MATCH FAIL.** The question asks for **annual totals** ("this year's TOTAL revenue divided by last year's TOTAL revenue") — one YoY ratio per product covering full-year sums. The answer instead returns **monthly YoY** (the SAME month last year vs the current month), which is a different metric. The SQL functions are valid Trino 467 (`date_add('month', -12, ...)`, `date_trunc('month', ...)`, `NULLIF`, `LEFT JOIN`), but the SHAPE answers a different question.

**Cleaner on-target answer** = conditional-SUM-by-year:

```sql
SELECT
  product_id,
  SUM(amount) FILTER (WHERE year(order_date) = year(current_date)) * 1.0
    / NULLIF(SUM(amount) FILTER (WHERE year(order_date) = year(current_date) - 1), 0) AS yoy_ratio
FROM orders
WHERE order_date >= date_add('year', -1, date_trunc('year', current_date))
GROUP BY product_id
```

Or equivalently `SUM(CASE WHEN year(order_date) = year(current_date) THEN amount ELSE 0 END) / NULLIF(SUM(CASE WHEN year(order_date) = year(current_date)-1 THEN amount ELSE 0 END), 0)`. Single pass, one row per product, exact target shape.

Verified `year(date)` returns integer (trino.io/docs/467/functions/datetime.html), `FILTER (WHERE ...)` valid on every aggregate (functions/aggregate.html docs-verbatim), `NULLIF(a, 0)` standard divide-by-zero guard. `date_add('month', -12, ...)` is also valid Trino 467.

| Dim | Score | Reason |
|---|---|---|
| Accuracy | 2.5 | Sql is valid Trino but computes monthly YoY, not annual-total YoY — wrong shape. |
| Completeness | 3.0 | Misses the "annual total" reading entirely; no conditional-SUM-by-year alternative shown. |
| Clarity | 3.5 | Code is readable but the choice of monthly bucketing for an annual question is not justified. |
| Actionability | 3.0 | Engineer copying this gets a different metric than asked — has to rewrite. |
| **Per-Q avg** | **3.0** | |

---

## Q3 — customers who ordered in EVERY one of the last 3 consecutive calendar months

`monthly_customers` CTE with GROUP BY customer + date_trunc('month', order_date), pre-filtered by `WHERE order_date >= date_add('month', -3, date_trunc('month', current_date))`, outer `HAVING COUNT(DISTINCT month) = 3`.

**BOUNDARY CHECK — partial.** The lower bound `date_add('month', -3, date_trunc('month', current_date))` is correct as the start of "3 full months ago". But there is **no upper bound**, so the window includes 4 distinct month buckets: 3-months-ago, 2-months-ago, 1-month-ago, AND the current (partial) month. `HAVING COUNT(DISTINCT month) = 3` then has edge cases:
- A customer active in all 3 prior full months but NOT the current month -> 3 distinct months -> correctly included.
- A customer active in all 3 prior full months AND the current month -> 4 distinct months -> **wrongly excluded** by `=3`.
- A customer active in current month + 2 of the prior 3 -> 3 distinct months -> **wrongly included**.

Cleaner form bounds both sides: `order_date >= date_add('month',-3,date_trunc('month',current_date)) AND order_date < date_trunc('month', current_date)` then `HAVING COUNT(DISTINCT month) = 3`. The core idea (`COUNT(DISTINCT month) = N consecutive months`) is right; the boundary handling needs the upper-bound bracket to align with "the last 3 FULL calendar months" reading.

`date_trunc('month', timestamp)` and `date_add('month', N, ...)` verified valid Trino 467 (functions/datetime.html).

| Dim | Score | Reason |
|---|---|---|
| Accuracy | 3.5 | Core pattern correct; missing upper bound on the date window makes the count semantics fragile. |
| Completeness | 4.0 | Pattern explained well; missed the "exclude current partial month" nuance. |
| Clarity | 4.0 | Well-structured CTE + HAVING; readable. |
| Actionability | 4.0 | Mostly copy-pasteable; engineer may notice the edge case in their own data. |
| **Per-Q avg** | **3.875** | |

---

## Q4 — group events by ISO week, count per week

`date_trunc('week', event_timestamp) AS week_start, COUNT(*) GROUP BY date_trunc('week', event_timestamp)`. Noted: date_trunc('week') is Monday-start ISO-8601; expression repeated in GROUP BY (no alias); `WHERE event_timestamp >= date_add('week', -12, current_date)`.

**LARGELY CORRECT.** Verified trino.io/docs/467/functions/datetime.html — `date_trunc('week', ts)` truncates to ISO 8601 week start which is Monday. The "repeat the GROUP BY expression, no output-alias" rule is correct for Trino 467 (sql/select.html: GROUP BY accepts input columns or ordinal positions, not output aliases). Timestamp >= date comparison is valid because Trino implicitly coerces date to timestamp for comparison (sql/types.html date/timestamp coercion).

| Dim | Score | Reason |
|---|---|---|
| Accuracy | 5.0 | All Trino 467 valid; Monday-ISO week claim verified; date-to-timestamp coercion valid. |
| Completeness | 5.0 | Anticipates the GROUP-BY-alias gotcha; gives time-window filter as bonus. |
| Clarity | 5.0 | Beginner-clear; ISO-8601 rationale stated. |
| Actionability | 5.0 | Direct copy-paste form; the WHERE pre-filter is the production-aware addition. |
| **Per-Q avg** | **5.0** | |

---

## Overall

- Per-Q average: (5.0 + 3.0 + 3.875 + 5.0) / 4 = **4.21875**.
- Dim-avg cross-check: Acc (5.0+2.5+3.5+5.0)/4 = 4.0 / Comp (5.0+3.0+4.0+5.0)/4 = 4.25 / Clar (5.0+3.5+4.0+5.0)/4 = 4.375 / Act (5.0+3.0+4.0+5.0)/4 = 4.25 -> avg = 4.21875. Agrees.
- **Governing label = PASS** (4.21875 >= 3.5; no per-Q quality-gate override per directive).
- Q2 (per-Q 3.0) flagged separately as **iter640 FIX-A candidate**.

---

## iter640 FIX-A directive (PRIMARY)

**Annual / period-total YoY-ratio canonical** at r07 §1a (analytical query patterns — time-series neighborhood). RECONCILE-IN-PLACE additive sub-canonical, do NOT rewrite existing month-over-month / LAG canonicals.

**Block heading**: `#### Sub-canonical — annual / period-total YoY ratio: conditional-SUM-by-year in a single SELECT (iter640 FIX-A)`

**Content** (exact, valid Trino 467):

1. **READ-THIS-FIRST keyword anchors**: "this year's total vs last year's total", "annual YoY ratio per product", "year-over-year growth ratio", "full-year revenue compared to prior year", "TY vs LY total", "this year total divided by last year total", "annual YoY per group", "yearly YoY ratio per product/customer".

2. **ONE-FACT LEAD**: For an ANNUAL-TOTAL YoY ratio (NOT month-over-month), use a single SELECT with two `FILTER (WHERE year(date_col) = year(current_date) [- 1])` conditional aggregates divided with `NULLIF(..., 0)`. ONE row per group, NO self-join, NO monthly bucketing.

3. **PRIMARY canonical (FILTER form)**:
   ```sql
   SELECT
     product_id,
     SUM(amount) FILTER (WHERE year(order_date) = year(current_date)) * 1.0
       / NULLIF(SUM(amount) FILTER (WHERE year(order_date) = year(current_date) - 1), 0) AS yoy_ratio
   FROM iceberg.analytics.orders
   WHERE order_date >= date_add('year', -1, date_trunc('year', current_date))
   GROUP BY product_id
   ```

4. **ALTERNATIVE canonical (CASE form, equivalent semantics)**:
   ```sql
   SELECT
     product_id,
     SUM(CASE WHEN year(order_date) = year(current_date)     THEN amount ELSE 0 END) * 1.0
       / NULLIF(SUM(CASE WHEN year(order_date) = year(current_date) - 1 THEN amount ELSE 0 END), 0) AS yoy_ratio
   FROM iceberg.analytics.orders
   WHERE order_date >= date_add('year', -1, date_trunc('year', current_date))
   GROUP BY product_id
   ```

5. **DO-NOT-WRITE table** with iter639 A2 form verbatim:
   - WRONG: monthly self-join (`monthly_revenue` CTE GROUP BY month + LEFT JOIN prev ON `date_add('month',-12,cur.month)` filtered to current month only) — answers a DIFFERENT question (CURRENT-MONTH-vs-SAME-MONTH-LAST-YEAR), not annual total YoY.
   - WRONG: omitting `NULLIF` on the denominator — divide-by-zero on first-year products.
   - WRONG: comparing `cur.month = date_trunc('month', current_date)` and calling it "this year's total" — restricts to one month.

6. **Cross-references**: to r07 month-over-month LAG canonical (different pattern, MoM not YoY), to r23 conditional-aggregation FILTER neighborhood.

7. **All SQL valid Trino 467**: `year(date)` returns int (functions/datetime.html), `FILTER (WHERE ...)` valid on every aggregate (functions/aggregate.html), `NULLIF(a,0)` standard, `date_add('year', -1, ...)`, `date_trunc('year', ...)` valid. No QUALIFY, no RLIKE, no PERCENTILE_CONT, no MEDIAN, no initcap, no dayname, no `::`-cast.

---

## iter640 FIX-B directive (SECONDARY, optional)

**"Last N FULL calendar months" boundary anchor** at r07 / r23 consecutive-month-active-customers neighborhood. Additive one-line guardrail:

- For "last N FULL calendar months" semantics, bound BOTH sides of the date window: `order_date >= date_add('month', -N, date_trunc('month', current_date)) AND order_date < date_trunc('month', current_date)`, then `HAVING COUNT(DISTINCT month_bucket) = N`. Otherwise the current partial month becomes a 4th bucket and `= N` mis-classifies customers active in current-month + some-prior-months.
- The pattern `COUNT(DISTINCT date_trunc('month', date_col)) = N` for "active in EVERY one of the last N consecutive months" is otherwise correct; the upper-bound exclusion is the one-line fix.

---

## DO NOT

- Touch r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe iter639).
- Re-edit the iter639 FIX-A listagg/array_join varchar-CAST sub-canonical at r07:§1a.2A (LANDED CLEAN this iter — durable).
- Rewrite iter534-638 locked canonicals.
- Add `::`-casts (iter571 PIN), QUALIFY, RLIKE (iter623 ban), PERCENTILE_CONT/MEDIAN (iter611 ban), EXTRACT(EPOCH) (iter562 ban), dayname/initcap fabrications, DISTINCT ON (iter634 ban).
- Bump training/state.json beyond what the run-prompt sets (do NOT bump).
- Git commit/push beyond appending the rubric score line (per directive).

---

## TOPIC AVG UPDATES

- **Analytical query patterns on Iceberg+Trino / r07**: Q1 listagg/array_join numeric-CAST FIX-A LANDED CLEAN +0.5; Q2 annual-total-vs-monthly target mismatch -0.5; Q3 consecutive-month boundary partial -0.25; Q4 date_trunc('week') ISO-Monday clean +0.25. Net mild DOWN.
- **SQL query best practices for OLAP / r23**: Q4 date_trunc('week') + GROUP BY repeat-expression clean +0.25. Net mild UP.
- Federation NOT probed — 4.49944/310 row UNCHANGED.

---

## Meta-note

Pattern over iter638 -> iter639: the numeric-coercion class (concat/format -> listagg/array_join) is now bulletproofed across the string-producing function family — Q1 here is the FIX-A landing confirmation. Q2 surfaces a NEW class: **annual / period-total YoY ratio** has no dedicated canonical — Haiku reaches for the month-over-month LAG / monthly self-join pattern when asked for ANNUAL totals. The fix is a dedicated conditional-SUM-by-year canonical at r07 with explicit "annual TOTAL" keyword anchors. Q3 surfaces a smaller but real boundary-handling nuance for "last N full months" semantics. Federation row at 4.49944/310 remains untouched for the 310th consecutive non-probe iteration — durability via breadth-elsewhere continues to keep the overall PASS margin healthy.

**OVERALL: 4.21875 PASS** — Q1 FIX-A listagg/array_join varchar-CAST LANDED CLEAN; Q4 ISO-week date_trunc bulletproof; Q3 consecutive-month boundary partial (off-by-current-partial-month); Q2 annual-total-vs-monthly target mismatch is the real-impact defect of this iter -> iter640 FIX-A = annual / period-total YoY-ratio conditional-SUM-by-year canonical at r07; iter640 FIX-B (optional) = last-N-full-calendar-months upper-bound anchor; federation row stays 4.49944/310.
