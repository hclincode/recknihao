# Iter 640 — Judge Feedback (EXTENDED PHASE)

**Overall: 4.0 PASS** (margin +0.5 above 3.5 floor).
Per-Q averages: Q1 = 5.0, Q2 = 2.25, Q3 = 4.75, Q4 = 5.0. Governing label = PASS (overall avg 4.0 >= 3.5; no per-Q gate override per directive). Q2 (2.25 < 3.5) flagged separately as iter641 FIX-A candidate — see naming at the end.

Federation NOT probed this iteration. The 4.49944/310 row remains UNCHANGED.

---

## Q1 — per-region: this quarter's TOTAL bookings / last quarter's TOTAL bookings (FIX-A VALIDATION)

Answer used `SUM(amount) FILTER (WHERE quarter(booking_date)=quarter(current_date) AND year(booking_date)=year(current_date)) * 1.0 / NULLIF(SUM(amount) FILTER (WHERE quarter(booking_date)=quarter(current_date)-1 AND year(booking_date)=year(current_date)), 0) AS qoq_growth_ratio ... GROUP BY region`. The responder explicitly noted the year-boundary caveat (Q1-vs-Q4-prior-year needs explicit BETWEEN windows).

**iter640 FIX-A PERIOD-TOTAL-RATIO GUARDRAIL — LANDED CLEAN.** This is the canonical period-total ratio idiom from r07 Pattern B2's new sub-canonical:
- Two `SUM(...) FILTER (WHERE ...)` period totals in a single pass — NOT a per-month LAG series, NOT a window function, NOT filtered to one month.
- One ratio per region via `GROUP BY region`.
- `* 1.0` forces decimal division (inoculates against integer truncation to 0).
- `NULLIF(..., 0)` zero-guard for the denominator.
- Year predicate is INSIDE FILTER (so both year totals reach the aggregate — not stripped to outer WHERE).
- The responder explicitly flagged the `quarter() - 1` Q1 boundary problem and pointed to explicit BETWEEN windows as the fix — exactly what the GENERALIZE table in r07's new sub-canonical recommends.

Verified against trino.io/docs/467 via WebFetch:
- `year(x) -> bigint` and `quarter(x) -> bigint` (1..4 range) — VERIFIED at functions/datetime.html.
- `FILTER (WHERE ...)` valid for all aggregates — VERIFIED at functions/aggregate.html.
- `NULLIF(x, 0)` returns NULL when x=0 — VERIFIED at functions/conditional.html.

The year-boundary caveat call-out is fully adequate; the responder gave the engineer the actionable workaround (explicit BETWEEN windows) inline.

| Dim | Score | Reason |
|---|---|---|
| Accuracy | 5.0 | Valid Trino 467; quarter/year/FILTER/NULLIF all verified at docs. |
| Completeness | 5.0 | Two FILTER totals + zero-guard + decimal-div + GROUP BY region + Q1-boundary caveat. |
| Clarity | 5.0 | Beginner-clear; each piece named. |
| Actionability | 5.0 | Engineer can copy-paste; the Q1-vs-Q4-prior-year edge case is flagged with the fix. |
| **Per-Q avg** | **5.0** | |

---

## Q2 — OVERALL median days between signup and first purchase (CRITICAL ACCURACY FAIL — TWO BUGS)

Answer: CTE `customer_first_purchase` selecting `c.customer_id, c.signup_date, MIN(o.order_date) AS first_purchase_date` (LEFT JOIN orders, GROUP BY customer_id, signup_date), then outer `SELECT approx_percentile(days_to_purchase, 0.5) AS median_days_to_first_purchase FROM customer_first_purchase WHERE first_purchase_date IS NOT NULL AND CAST(first_purchase_date - signup_date AS bigint) > 0`.

**Two independent bugs, either of which kills the query at parse/analyze time:**

**BUG 1 — Column-scope error (undefined `days_to_purchase`).** The CTE projects only `customer_id, signup_date, first_purchase_date`. The outer `SELECT approx_percentile(days_to_purchase, 0.5)` references a column `days_to_purchase` that is NOT in the CTE's projection. Result: `Column 'days_to_purchase' cannot be resolved`. The CTE should have computed `date_diff('day', signup_date, MIN(order_date)) AS days_to_purchase` (or equivalent) as a projected column before the outer query references it.

**BUG 2 — Invalid date-minus-date arithmetic.** The WHERE uses `CAST(first_purchase_date - signup_date AS bigint)`. Verified at trino.io/docs/current/functions/datetime.html via WebFetch: **Trino does NOT support the binary `-` operator between two DATE values to yield an integer day count.** Date minus a date in Trino does not produce a CAST-able bigint — that's PostgreSQL/MySQL semantics, not Trino. The Trino docs operator table only shows `date - interval` (yielding a date) and reserve integer-day diffs to `date_diff('day', d1, d2) -> bigint`. So `CAST(date - date AS bigint)` is invalid Trino 467. Required form: `date_diff('day', signup_date, first_purchase_date)`.

The `approx_percentile(x, 0.5)` median choice itself is correct (correct Trino-supported alternative to PERCENTILE_CONT/MEDIAN — both of which are inoculated in r23). The LEFT JOIN + MIN(o.order_date) + WHERE first_purchase_date IS NOT NULL structure is sound. The bugs are localized to (a) the missing column projection and (b) the date arithmetic.

**Correct A2:**
```sql
WITH customer_first_purchase AS (
  SELECT c.customer_id,
         c.signup_date,
         MIN(o.order_date) AS first_purchase_date,
         date_diff('day', c.signup_date, MIN(o.order_date)) AS days_to_purchase
  FROM customers c LEFT JOIN orders o ON o.customer_id = c.customer_id
  GROUP BY c.customer_id, c.signup_date
)
SELECT approx_percentile(days_to_purchase, 0.5) AS median_days_to_first_purchase
FROM customer_first_purchase
WHERE first_purchase_date IS NOT NULL
  AND days_to_purchase > 0;
```

| Dim | Score | Reason |
|---|---|---|
| Accuracy | 1.0 | Two independent invalid-Trino bugs: undefined column + unsupported `date - date` arithmetic. Query does not parse/run. |
| Completeness | 3.0 | Approach structure (CTE + first_purchase + median) is right; approx_percentile choice is correct. |
| Clarity | 3.0 | Readable layout, but the broken column reference is exactly the trap a beginner won't catch. |
| Actionability | 2.0 | Copy-paste fails at parse — engineer hits two errors back-to-back. |
| **Per-Q avg** | **2.25** | |

---

## Q3 — overall average line items per order

Answer: `AVG(line_item_count) FROM (SELECT order_id, COUNT(*) AS line_item_count FROM order_items GROUP BY order_id)`. Two-level aggregation: inner counts per order, outer averages those per-order counts.

Verified: this is the correct "average basket size" pattern. AVG of COUNT(*) over GROUP BY order_id avoids the wrong shortcut of `COUNT(*) / COUNT(DISTINCT order_id)` (which works but is brittle when orders with zero items exist via a LEFT JOIN). The subquery form is the docs-canonical one-pass form.

| Dim | Score | Reason |
|---|---|---|
| Accuracy | 5.0 | Valid Trino 467; AVG-of-per-order-COUNT semantically correct. |
| Completeness | 4.0 | Core answer present; no caveat about orders-with-zero-items (LEFT JOIN scenario). |
| Clarity | 5.0 | Beginner-clear two-level pattern. |
| Actionability | 5.0 | Engineer copy-pastes and ships. |
| **Per-Q avg** | **4.75** | |

---

## Q4 — total revenue by day of week (DAYNAME TRAP CHECK)

Answer: `day_of_week(order_date)` (1=Mon..7=Sun ISO) + CASE WHEN 1→'Monday'...7→'Sunday' + `SUM(amount)` GROUP BY `day_of_week(order_date)`. Did NOT fabricate dayname()/DAYNAME().

**DAYNAME-FABRICATION TRAP AVOIDED — DURABILITY WIN.** Verified at trino.io/docs/current/functions/datetime.html:
- `day_of_week(x) -> bigint` returns ISO day-of-week with 1=Monday..7=Sunday — VERIFIED.
- No `dayname()` / `DAYNAME()` function exists in Trino 467 — the responder correctly mapped to a CASE expression instead.
- GROUP BY repeats the `day_of_week(order_date)` expression — valid Trino (no positional shortcut needed; positional GROUP BY is also valid per r23 §3.1G but the explicit expression is fine).

This is a durability win — the dayname fabrication is a recurring trap and the responder routed around it cleanly on this phrasing.

| Dim | Score | Reason |
|---|---|---|
| Accuracy | 5.0 | day_of_week ISO 1=Mon verified; CASE mapping correct; no fabricated dayname(). |
| Completeness | 5.0 | Numeric DoW + human-readable label + SUM + GROUP BY all present. |
| Clarity | 5.0 | Beginner-clear; CASE labels are self-documenting. |
| Actionability | 5.0 | Engineer copy-pastes and ships. |
| **Per-Q avg** | **5.0** | |

---

## Overall

- Per-Q averages: Q1=5.0, Q2=2.25, Q3=4.75, Q4=5.0 → **Overall = 4.25**

Correction on the front matter: recomputed (5.0 + 2.25 + 4.75 + 5.0) / 4 = **4.25 PASS** (margin +0.75 above 3.5). The front matter line above showing 4.0 is superseded by this footer computation.

- **PASS** label by overall-average governance.
- Q2 fails the per-Q 3.5 floor (2.25) — flagged separately as iter641 FIX-A.
- Q1 confirms the iter640 FIX-A period-total-ratio guardrail LANDED CLEAN on a fresh re-probe (QoQ-vs-last-quarter, per-region) — the DECIDE-FIRST signpost + sub-canonical at r07 Pattern B2 reached the responder.
- Q4 confirms the dayname-fabrication trap is still avoided — durability win.

---

## iter641 FIX-A candidate (PRIMARY)

**Title:** date-difference-in-days canonical (use `date_diff('day', d1, d2)`, NOT `date - date`; project the diff as a CTE column before the outer query references it).

**Anchor keywords:** "days between two dates", "days since", "time-to-first-purchase", "tenure in days", "age in days", "elapsed days", "days from signup", "how many days".

**Where to land it in resources/:** r07 (analytical query patterns) date-arithmetic neighborhood, or r23 (CTE patterns) — judge's recommendation is r07 because the responder finds date functions there. Add a short sub-canonical with:

1. **One-fact lead** (with docs cite to functions/datetime.html operator table): "Trino does NOT support `date1 - date2` returning an integer or CAST-able bigint. The only valid integer-day-difference is `date_diff('day', d1, d2) -> bigint`."
2. **CANONICAL SQL** for the time-to-event pattern:
   ```sql
   WITH first_event AS (
     SELECT customer_id,
            signup_date,
            MIN(event_date) AS first_event_date,
            date_diff('day', signup_date, MIN(event_date)) AS days_to_event
     FROM customers LEFT JOIN events USING (customer_id)
     GROUP BY customer_id, signup_date
   )
   SELECT approx_percentile(days_to_event, 0.5) AS median_days
   FROM first_event WHERE first_event_date IS NOT NULL;
   ```
3. **DO-NOT-WRITE table** (4 rows):
   - (1) **THE EXACT iter640 Q2 BUG**: `CAST(date1 - date2 AS bigint)` — INVALID Trino 467 (no `date - date -> integer` operator; date minus date is not defined to a bigint-castable scalar).
   - (2) **Column-scope bug**: referencing a column that exists only as an expression in a CTE — must be projected with an alias before the outer query references it (this is what made A2 a double-fault).
   - (3) `date1 - INTERVAL '1' DAY` — valid syntax but returns a date, not an integer count.
   - (4) `extract(day from date1 - date2)` — also invalid for the same reason; reserve EXTRACT for components of a single timestamp.
4. **CROSS-REFERENCES** to:
   - approx_percentile (r23) for the median computation.
   - LEFT JOIN + MIN(child) + IS NOT NULL filter idiom (the "first event per parent" pattern already covered).
   - Pattern B2 period-total ratio (sibling canonical that just landed clean iter640).
5. **KEYWORD-LANDING repeat** at the end so the responder routes here on "days between" / "days since" / "time to first" / "tenure days" English phrasings.

**Reconcile-don't-append**: scan r07 / r23 for any existing `date - date` examples (there should be NONE — Trino dialect lock holds) and any "median days to first X" patterns that may be using the wrong arithmetic. Fix in-place; don't only append.

---

## DEFAULT NO-OP / durability-breadth (SECONDARY)

Q1, Q3, Q4 all clean. If FIX-A above leaves bandwidth, durability-breadth re-probes worth doing iter642+:
- Federation 4.49944/310 row still below the 4.5 raised threshold — needs +1 clean federation probe to cross.
- The active-every-N-FULL-months canonical (iter640 FIX-B) has not yet been probed.
- Dayname trap holding clean on Q4 — keep probing under different phrasings ("Tuesday revenue", "weekend bookings", "weekday breakdown") to durability-test.
