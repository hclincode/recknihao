# Judge Feedback — Iter 908 (EXTENDED PHASE, NO-OP durability sweep)

**Overall: 4.84 PASS** — per-Q 5.00 / 5.00 / 5.00 / 4.375 = 19.375 / 4 = 4.84 (margin +1.34 over 3.5).
Overall average governs — no per-Q veto. **NO-OP confirmed: zero defects, zero edits.**

Federation NOT probed (4.49944 / 310 row UNCHANGED — still the only un-passed row).

All four dialect facts VERIFIED vs trino.io/docs/467 (aggregate.html, window.html, select.html, comparison.html, datetime.html) + WebSearch 2026-06-10. PIN 467.

---

## Q1 — cheapest + most expensive order per region, same row → 5.00
`SELECT region, MIN(order_value) AS cheapest_order, MAX(order_value) AS most_expensive_order FROM orders GROUP BY region`

CORRECT. VERIFIED aggregate.html: multiple aggregate functions (MIN and MAX) in a single GROUP BY query are valid and computed in a **single pass / single scan** over the grouped data — no self-join, no two-query UNION needed. Two aggregates land on the **same output row per region** exactly as asked. The "one query, two aggregates, no join" framing is accurate and the most efficient form. Acc 5 / Comp 5 / Clar 5 / Act 5.

## Q2 — count of a customer's orders above that customer's own average → 5.00 (WINDOW FUNCTION USED CORRECTLY)
`SELECT COUNT(*) AS orders_above_customer_average FROM (SELECT customer_id, order_value, AVG(order_value) OVER (PARTITION BY customer_id) AS customer_avg FROM orders) WHERE order_value > customer_avg`

CORRECT — **clean, canonical window-function pattern.** VERIFIED window.html: `AVG(order_value) OVER (PARTITION BY customer_id)` materializes the per-customer average onto every row in the inner subquery; the outer `WHERE order_value > customer_avg` filters on `customer_avg`, which is a **REAL materialized subquery column**, NOT a window function in WHERE. This is the textbook "compute window value in subquery, filter in outer query" rewrite (Trino has no QUALIFY). `COUNT(*)` then counts the surviving rows = orders above their own customer's average. Semantics exactly correct.

**EXPLICIT NOTE: the iter904/906 over-reach pattern did NOT appear.** This is the *correct* use of a window function — there is NO window-fn-in-WHERE (the iter904 Q1 slip) and NO window-over-grouped-column muddle (the iter906 Q2 slip). The responder produced the clean subquery+outer-filter form with no broken lead query. Acc 5 / Comp 5 / Clar 5 / Act 5.

## Q3 — average basket size (avg distinct products per order) → 5.00
`SELECT AVG(product_count) AS avg_basket_size FROM (SELECT order_id, COUNT(DISTINCT product_id) AS product_count FROM line_items GROUP BY order_id)`

CORRECT. VERIFIED aggregate.html: two-level aggregation is valid — inner `COUNT(DISTINCT product_id) GROUP BY order_id` gives the distinct-product count per order; outer `AVG(product_count)` averages those counts. `AVG` over an integer count returns a **double** in Trino (documented integer→double promotion for AVG), so fractional basket sizes (e.g. 2.7) are preserved — correct for an "average basket size" metric. DISTINCT correctly de-dupes the same product appearing on multiple line items within one order. Acc 5 / Comp 5 / Clar 5 / Act 5.

## Q4 — count orders placed on a holiday date → 4.375 (Comp 3.5)
`SELECT COUNT(DISTINCT o.order_id) AS orders_on_holidays FROM orders o INNER JOIN holidays h ON o.order_date = h.holiday_date`

CORRECT & RUNS. VERIFIED select.html + comparison.html: INNER JOIN on date equality is valid; `COUNT(DISTINCT o.order_id)` correctly guards against an order being counted multiple times if the holidays table has duplicate rows for a date. Semantics right — only orders whose date matches a holiday survive the inner join.

**Deduction = COMPLETENESS NUANCE, NOT an accuracy defect.** If `order_date` is a **timestamp** (time-of-day component) and `holiday_date` is a **date**, the equality `o.order_date = h.holiday_date` will almost never match: Trino implicitly casts the DATE to a timestamp at **midnight** (zero time), so only orders placed at exactly 00:00:00 join (VERIFIED issue #12729 / comparison coercion behavior). The robust form is `ON CAST(o.order_date AS date) = h.holiday_date` (or `date_trunc('day', o.order_date)`). The answer is fully correct when both columns are date-typed, but did not flag the timestamp-vs-date matching caveat that a SaaS engineer with a timestamped `order_date` would hit. Acc 5 / Comp 3.5 / Clar 4.5 / Act 4.5 = 4.375.

---

## Verdict: NO-OP — teacher ZERO edits

- All 4 queries are dialect-clean and semantically correct for Trino 467.
- **Q2 confirms the window-function-in-subquery + outer-filter pattern is internalized correctly** — the iter904 (window-fn-in-WHERE) and iter906 (window-over-grouped-column) one-off slips did NOT recur. No findability anchor / no "wrong" card needed for those (would risk defang-backfire + duplicate the existing window-eval-order / GROUP-BY-output pins).
- No genuine findable-but-missing gap rose to FIX-A. The Q4 timestamp-vs-date JOIN coercion caveat is a real-world nuance but is a **completeness nuance, not a dialect defect** and not worth a card (the answer is correct as written for date-typed columns; a CAST(... AS date) tip would be the only optional micro-addition, and only if it touches NO existing date/JOIN pin — **SKIP**, churn risk).

### Directives for iter909
- **DEFAULT NO-OP.** Do NOT add any "wrong" card for Q1–Q4 (all correct). Do NOT mark Q1 multi-aggregate-one-GROUP-BY, Q2 window-in-subquery+outer-filter, Q3 two-level AVG-of-COUNT(DISTINCT), or Q4 INNER-JOIN-on-date+COUNT(DISTINCT) wrong.
- OPTIONAL micro-anchor ONLY if it touches NO existing pin: a 1-line "joining a TIMESTAMP order_date to a DATE holiday_date needs `CAST(order_date AS date)` (raw `=` only matches midnight)" near a date-comparison/JOIN card — **SKIP if it churns or duplicates any date-coercion / JOIN-key pin** (Q4 is correct as-is for date columns).
- Re-probe fresh adjacents next sweep. Federation (4.49944 / 310) is the only un-passed row — bulletproofed angles only.
- Do NOT touch any iter534–907 pin. PIN 467. NO federation edits.
- **DO NOT bump training/state.json** (already passed; overall 4.84 PASS holds).
