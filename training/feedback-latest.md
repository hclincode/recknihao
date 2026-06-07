# Judge Feedback — Iter 607 (EXTENDED PHASE)

**Verdict: CLEAN SWEEP. Overall ~4.97/5.0 — STRONG PASS (margin +1.47 above the 3.5 floor).**

This was a durability/breadth probe across four canonical analytical-SQL idioms (subtotals+grand-total via ROLLUP, MoM delta via LAG, first-purchase via MIN…GROUP BY, divide-by-zero-guarded conversion rate via NULLIF). All four answers are textbook-correct, valid Trino 467, and directly actionable. No fabrications, no `::` casts, no QUALIFY, no invalid clause placement. The teacher's NO-OP decision for this iteration is vindicated — resources routed every question cleanly first-probe.

---

## Per-question scores

### Q1 — Per-category subtotals + grand-total row (ROLLUP)
Answer: `SELECT CASE GROUPING(category) WHEN 0 THEN category WHEN 1 THEN 'GRAND TOTAL' END AS category, SUM(revenue) AS total_revenue FROM subscriptions GROUP BY ROLLUP(category) ORDER BY GROUPING(category), category NULLS LAST`

| Dimension | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
| **Average** | **5.00** |

Verified against trino.io/docs/467/sql/select.html:
- `GROUP BY ROLLUP(category)` is valid; "The `ROLLUP` operator generates all possible subtotals for a given set of columns" — for a single column this yields one row per category PLUS a grand-total row with `category` NULL.
- `GROUPING(category)`: docs — "a bit is set to 0 if the corresponding column is included in the grouping and to 1 otherwise." So a detail row returns 0, the grand-total row returns 1. The `CASE GROUPING(category) WHEN 0 THEN category WHEN 1 THEN 'GRAND TOTAL' END` labeling is therefore exactly correct — this is the single most error-prone part of the question and the responder nailed it (labels the total row rather than leaking a NULL).
- `ORDER BY GROUPING(category), category NULLS LAST` is valid; GROUPING() is usable in ORDER BY and deterministically sinks the total row to the bottom. The trailing `category NULLS LAST` is mild belt-and-suspenders (GROUPING already separates 0 from 1) but harmless and valid — not a defect.

No slip. Gold-standard answer for a subtotals+grand-total question.

### Q2 — Month-over-month delta without a self-join (LAG)
Answer: `SELECT month, revenue, LAG(revenue,1) OVER (ORDER BY month) AS prev_month_revenue, revenue - LAG(revenue,1) OVER (ORDER BY month) AS mom_change FROM monthly_revenue ORDER BY month`

| Dimension | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 4.75 |
| Clarity | 5 |
| Actionability | 5 |
| **Average** | **4.9375** |

Verified against trino.io/docs/467/functions/window.html: `lag(x[, offset[, default_value]])` "returns the value at offset rows before the current row… If the offset refers to a row that is not within the partition, the default_value is returned, or if it is not specified null is returned." So `LAG(revenue,1)` returns the prior month's revenue and NULL for the first month → `mom_change` is NULL for month 1, which is the correct (not zero, not erroring) behavior. No self-join; referencing LAG twice in the SELECT is perfectly valid. Clean.

Sole reason completeness is 4.75: a one-line note that the first month's delta is NULL (and optionally that a wrapping subquery could also yield a % change) would round it out. Not score-affecting at the question level — the SQL is fully correct.

### Q3 — First-ever purchase date per customer (MIN…GROUP BY)
Answer: `SELECT customer_id, MIN(order_date) AS first_purchase_date FROM orders GROUP BY customer_id ORDER BY customer_id`

| Dimension | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
| **Average** | **5.00** |

`MIN(order_date) … GROUP BY customer_id` is the simplest, most efficient correct form — one row per customer, earliest date. The responder did NOT over-engineer this into a ROW_NUMBER()/min_by() construction (correct but heavier and the wrong tool for "earliest DATE only"). Resource r07:370 first-seen-per-user MIN canonical routed perfectly. Clean.

### Q4 — Conversion rate guarded against divide-by-zero (NULLIF)
Answer: `SELECT landing_page, COUNT(DISTINCT CASE WHEN is_signup=true THEN session_id END) AS signups, COUNT(DISTINCT session_id) AS page_visits, ROUND(100.0 * COUNT(DISTINCT CASE WHEN is_signup=true THEN session_id END) / NULLIF(COUNT(DISTINCT session_id),0), 2) AS conversion_rate_pct FROM page_events GROUP BY landing_page ORDER BY landing_page`

| Dimension | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 4.75 |
| Actionability | 5 |
| **Average** | **4.9375** |

Verified against trino.io/docs/467/functions/conditional.html: NULLIF — "Returns null if value1 equals value2" otherwise returns value1. So `NULLIF(COUNT(DISTINCT session_id), 0)` returns NULL when visits = 0, and `numerator / NULL → NULL` (no DIVISION_BY_ZERO error, no infinity). Correct, idiomatic guard. Additional correctness points:
- `COUNT(DISTINCT CASE WHEN is_signup=true THEN session_id END)` is a valid conditional distinct count (CASE with no ELSE → NULL → excluded from COUNT DISTINCT).
- `100.0 *` forces DECIMAL arithmetic, avoiding the integer-division-to-0 trap.
- `is_signup = true` is valid for a boolean column (bare `is_signup` would be equally valid — not a nit).

Clarity 4.75 only because a single sentence explaining WHY NULLIF prevents the error (NULL propagation through division) would help the OLAP-novice audience; the SQL itself is flawless.

---

## Overall

| Question | Avg |
|---|---|
| Q1 ROLLUP/GROUPING | 5.00 |
| Q2 LAG MoM | 4.9375 |
| Q3 MIN first-purchase | 5.00 |
| Q4 NULLIF conversion guard | 4.9375 |
| **Overall** | **4.96875** |

Per-directive dimension-average roll-up (average of the four dimension-averages across the four questions): Accuracy 5.00, Completeness 4.9375, Clarity 4.9375, Actionability 5.00 → **overall 4.96875**. **PASS** by a wide margin.

All four confirmed CLEAN: valid Trino 467 throughout, zero `::` casts, zero QUALIFY, zero invalid clause placement, zero fabricated functions, zero off-by-one in the GROUPING bit logic or LAG offset. Exactly the expected good outcome for a durability/breadth iteration.

## Topic movement
- **SQL query best practices for OLAP / Analytical query patterns on Iceberg+Trino**: UP/stable. Q1 (ROLLUP subtotals+grand-total), Q2 (LAG MoM), Q3 (first-seen MIN), Q4 (NULLIF guard) all clean — reinforces r28 ROLLUP, r07 LAG/MIN-first-seen, and r07/r27 NULLIF locks.
- **Federation (4.49944/310, FAIL row)**: NOT probed this iteration — row UNCHANGED. Still the only sub-4.5 topic and the lone gating item.

## Diagnosis of slips
None. No content-gap, no landing-point-miss, no routed-but-mis-applied, no copy-paste-incompleteness, no resource-defect. The two sub-5.00 sub-scores (Q2 completeness, Q4 clarity) are minor "could add one explanatory sentence" polish items, NOT errors — they do not warrant a resource edit and would risk churn against a stable corpus.

## Recommendation for iter608
**Default to a durability/breadth NO-OP.** No fabrication or slip surfaced; resources routed all four canonical idioms cleanly first-probe. Do NOT manufacture edits to chase the trivial Q2/Q4 polish nits — that is exactly the churn this phase avoids. If iter608 wants signal that moves the needle, **probe the federation row (4.49944/310)** — the only sub-threshold topic — using only the bulletproofed r22 §13.x angles (predicate pushdown, cross-catalog join limits, when-to-federate-vs-ingest), per the standing thin-margin guidance. Otherwise hold NO-OP and preserve all iter534-606 locks.
