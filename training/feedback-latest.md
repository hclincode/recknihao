# Judge Feedback — iter910 (re-probe sweep)

**Overall: 4.875 STRONG PASS** (Q1 5.00 / Q2 4.75 / Q3 5.00 / Q4 4.75)
Phase: extended. Teacher edits this iter: ZERO (re-probe + 3 fresh adjacents). DO NOT bump state.json (already 910).

All dialect claims verified vs trino.io/docs/467 (datetime / window / array / aggregate / conversion .html) via WebFetch 2026-06-10. Trino 467 PINNED. Production stack (on-prem Trino 467 + Iceberg + MinIO + JWT/OPA) unaffected — all four answers are pure portable SQL.

---

## Q1 — top-5 products' revenue as % of total — 5.00 CLEAN

**iter909 bare-column-in-GROUP-BY / GROUP-BY-1-on-aggregate muddle: ONE-OFF CONFIRMED — did NOT recur. The iter909 slip is CLOSED. NO findability-anchor FIX-A needed.**

Primary query verified clean:
- Inner CTE `ranked_products`: `GROUP BY product_id`; `SUM(revenue) AS total_revenue` is an aggregate; `ROW_NUMBER() OVER (ORDER BY SUM(revenue) DESC)` is a window over an aggregate — VALID. Window functions run after GROUP BY/HAVING (verified window.html "run after the HAVING clause"), so ordering the window by `SUM(revenue)` is legal. **NO bare non-aggregated column this time.**
- Outer query: a SINGLE SCALAR aggregate `ROUND(100.0 * SUM(CASE WHEN product_rank <= 5 THEN total_revenue ELSE 0 END) / SUM(total_revenue), 2)` over `ranked_products` with NO GROUP BY — correct. NOT the iter909 GROUP-BY-1-on-an-aggregate error. `100.0` decimal promotion correctly avoids integer-division truncation.

Second alt (FILTER + JOIN) also VALID: `ranked_products` with `product_id` + rank, JOIN `sales`, `SUM(revenue) FILTER (WHERE product_rank <= 5) / SUM(revenue)`. FILTER-on-aggregate confirmed aggregate.html.

## Q2 — calendar days with zero sales in March 2026 — 4.75 CLEAN

- `sequence(DATE '2026-03-01', LAST_DAY_OF_MONTH(DATE '2026-03-01'), INTERVAL '1' DAY)` → date array (verified array.html: sequence(start,stop,step) with INTERVAL DAY TO SECOND step over dates) + UNNEST valid.
- `last_day_of_month(date)` EXISTS in 467 (verified datetime.html `last_day_of_month(x) → date`).
- `DATE(order_date)` cast valid; date-range filter `>= DATE '2026-03-01' AND < DATE '2026-04-01'` correct half-open month window.
- `COUNT(*) - COUNT(active_days.order_day)` over the LEFT JOIN correctly yields dead days (calendar days with no matching active day → order_day NULL → not counted by COUNT(col)). Verified COUNT(col) ignores NULLs, COUNT(*) counts rows.
- Minor (not a defect, no penalty): `COALESCE(COUNT(...), 0)` is redundant — COUNT never returns NULL.

## Q3 — products ordered in every one of the last 3 full months — 5.00 CLEAN

- `order_date >= date_add('month', -3, date_trunc('month', current_date)) AND order_date < date_trunc('month', current_date)` = exactly the three most-recent FULL months (excludes the current partial month). Verified date_add(unit,value,ts) (negative value subtracts) + date_trunc.
- `GROUP BY product_id HAVING COUNT(DISTINCT date_trunc('month', order_date)) = 3` correctly requires presence in all 3 distinct months. Valid in 467.

## Q4 — days between each order and that customer's first-ever order — 4.75 CLEAN

- `customer_first_order` CTE: `MIN(order_date)` per `customer_id` (GROUP BY) — valid, MIN(date) confirmed.
- `date_diff('day', f.first_order_date, o.order_date)` = `order_date − first_order_date` as bigint complete days (verified datetime.html `date_diff(unit, ts1, ts2) → bigint`, returns ts2−ts1). Earlier-first → positive day count. "Jan 1 → Jan 15 = 14" correct (day-aware count, NOT 15).
- Minor (no penalty): for the customer's own first order the value is 0, as expected.

---

## Verdict

- **Q1 muddle ONE-OFF CONFIRMED** (did NOT recur). iter909 slip CLOSED.
- **NO dialect defect, NO fabrication, NO wrong-signature, NO crossed-family, NO findability slip, NO prod-env conflict** across all 4. Every function verified present with correct signature in Trino 467.
- **iter911 = DEFAULT NO-OP / durability sweep.** No LIGHT FIX-A warranted. Optional fresh adjacents next sweep: gap-filling with sequence over month/year intervals, FILTER-vs-CASE share variants, multi-level HAVING-COUNT-DISTINCT presence checks. PRESERVE full iter534–909 pin inventory; NO federation edits (federation 4.49944/310).

DO NOT bump training/state.json (already 910).
