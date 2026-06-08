# Iter691 Judge Feedback — 2026-06-08 (EXTENDED PHASE)

**Phase:** extended (no-op iter; teacher made zero edits to validate durability across iter689→iter691)

**Verdict:** PASS (overall avg 4.19 / 5; threshold 3.5)

---

## Per-question scores

### Q1 — Funnel / ordered sequence (signup → add_payment → purchase)
**Approach:** CTE-chain funnel (signups → payments JOIN-on user_id with event_time > signup_time → purchases JOIN-on signups+payments with event_time > signup_time), UNION-ALL of COUNT(*) per stage. Also offered correlated-EXISTS variant and named MATCH_RECOGNIZE as the strict-order alternative.

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 3 | The CTE-chain shape is valid Trino 467 SQL. **Ordering-precision looseness:** purchases CTE checks `purchase.event_time > signup.event_time` AND user-in-payments, but does NOT check `purchase.event_time > payment.event_time`. So a user with signup→purchase→payment (purchase BEFORE payment) still qualifies — strict signup→payment→purchase ordering is not fully enforced. The COUNT-drop-off skeleton is right; the temporal predicate stitching is one inequality short. |
| Completeness | 4 | Three stages + per-stage count + variants. Naming MATCH_RECOGNIZE as a cleaner strict-order option is helpful. Could have written the MATCH_RECOGNIZE form explicitly since r07:508-526 already documents it. |
| Clarity | 4 | CTE structure is readable; per-stage count drop-off is intuitive. |
| Actionability | 4 | Engineer can copy-paste and run; loose-ordering effect would only hit sub-1% of users where events arrive out of business order, so usable as-is for most funnel reports. |

**Avg: 3.75**

### Q2 — Calendar-aware 7-day rolling average of DAILY REVENUE
**Approach:** `SELECT order_date, AVG(amount) OVER (ORDER BY order_date RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW) FROM iceberg.analytics.orders WHERE order_date >= CURRENT_DATE - INTERVAL '90' DAY ORDER BY order_date;`

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 2 | **GRAIN ERROR — the main defect of this iter.** The `RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW` calendar-aware frame mechanic IS correct Trino 467 (value-based, gap-day robust; verified at trino.io/docs/current/functions/window.html). BUT averaging `amount` directly over the **raw orders** table averages **individual order amounts**, NOT daily-revenue totals. With multiple orders sharing an `order_date`, the RANGE-INTERVAL frame on a non-unique ORDER BY key includes every peer-row in the 7-day window — the result is the **mean order size** over trailing 7 days, NOT the rolling average of daily revenue. Output is also one row per ORDER (not one per day). Pattern D r07:2946-3034 (the iter649 FIX-A pin) explicitly mandates a daily pre-aggregate CTE FIRST: `WITH daily AS (SELECT order_date, SUM(amount) AS daily_revenue FROM orders GROUP BY order_date) SELECT order_date, AVG(daily_revenue) OVER (ORDER BY order_date RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW) FROM daily;`. The responder cited Pattern D but did NOT apply the pre-aggregate step. |
| Completeness | 3 | Calendar-aware frame chosen (gap-day robust) is the right idea; missing the daily-CTE pre-aggregate makes the query answer a different question than asked. No callout that a dashboard tile labelled "7-day rolling average of daily revenue" backed by this query would silently report mean order size. |
| Clarity | 4 | Single tight SELECT, ORDER BY for readability. |
| Actionability | 3 | If the engineer pastes this they get a wrong metric. They need to know "wrap in daily CTE first" before shipping. |

**Avg: 3.0** — weakest answer; the grain mismatch is a metric-correctness bug, not a cosmetic issue.

### Q3 — GROUPING SETS / CUBE multi-grain (region, product subtotals + grand total + label)
**Approach:** `GROUP BY CUBE(region, product)` + `CASE GROUPING(region, product) WHEN 0 THEN 'Detail' WHEN 1 THEN 'Region Total' WHEN 2 THEN 'Product Total' WHEN 3 THEN 'Grand Total' END`.

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | `CUBE(region, product)` ≡ `GROUPING SETS ((region,product),(region),(product),())` = exactly the 4 grains asked. GROUPING() bitmask verified against trino.io/docs/current/functions/aggregate.html: leftmost arg = MSB; bit SET when column rolled up. 0=both present (Detail), 1=binary 01=product rolled up (Region Total = per-region subtotal), 2=binary 10=region rolled up (Product Total = per-product subtotal), 3=binary 11=both rolled up (Grand Total). All four labels correct. |
| Completeness | 5 | Detail + per-region + per-product + grand total + label column + readable ORDER BY (NULLS LAST so subtotal rows sort cleanly). |
| Clarity | 5 | One query, one CASE expression, idiomatic. |
| Actionability | 5 | Copy-paste runnable. |

**Avg: 5.0**

### Q4 — UNNEST line_items with ordinality
**Approach:** `CROSS JOIN UNNEST(line_items) WITH ORDINALITY AS t(line_item, item_position)`; explained 1-based, element-first-ordinality-last, walked through `'shoes','socks','belt' → 1,2,3`; explicitly called out that ROW_NUMBER would assign a new ordering rather than the original array position.

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | Verified against trino.io/docs/current/sql/select.html: ordinality column is appended LAST in the alias list, 1-based. Element-first/ordinality-last alias order correct. ROW_NUMBER-vs-ordinality distinction exactly right. |
| Completeness | 5 | Worked example + position semantics + the common ROW_NUMBER anti-pattern. |
| Clarity | 5 | Concrete `'shoes','socks','belt' → 1,2,3` example makes 1-based indexing immediately obvious. |
| Actionability | 5 | Direct copy-paste. |

**Avg: 5.0**

---

## Overall

| Q | Avg |
|---|---|
| Q1 (funnel) | 3.75 |
| Q2 (rolling daily revenue) | 3.00 |
| Q3 (CUBE multi-grain) | 5.00 |
| Q4 (UNNEST ordinality) | 5.00 |
| **Overall** | **4.1875 PASS** |

Q2 is the visible drag — flagged in prose per directive, not used as a per-question override.

---

## Critical findings

### Q2 GRAIN error verdict (explicit)
The responder produced **AVG(individual order amount) over a calendar 7-day window**, NOT **AVG(daily revenue totals) over a calendar 7-day window**. These are different metrics. With the raw orders table and a non-unique `ORDER BY order_date` key, the RANGE-INTERVAL frame pulls every peer order within the window — the output is the mean per-order amount over trailing 7 days, multiplied across one output row per order (not one row per day). The corrected form:

```sql
WITH daily AS (
  SELECT order_date, SUM(amount) AS daily_revenue
  FROM iceberg.analytics.orders
  GROUP BY order_date
)
SELECT order_date, daily_revenue,
       AVG(daily_revenue) OVER (
         ORDER BY order_date
         RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW
       ) AS rolling_7d_avg_revenue
FROM daily
ORDER BY order_date;
```

Resource Pattern D at r07:2946-3034 already documents this canonically — the LEADING CANONICAL block at r07:2955+ is the exact iter648 Q2 fix shape. **Resource is correct; responder did not apply it.**

### Q1 ordering-precision note
The CTE-chain enforces `payment > signup` and `purchase > signup` but NOT `purchase > payment`. A user with chronological signup → purchase → payment_added survives the funnel. For strict order, MATCH_RECOGNIZE PATTERN `(signup payment+ purchase+)` is cleaner — the responder named MATCH_RECOGNIZE as an option but didn't write it out. Minor; not a PASS-killer.

---

## iter692 directive recommendation: **DEFAULT NO-OP** (no FIX-A)

Pattern D r07:2946-3034 already:
- Has a DECIDE-FIRST grain block at r07:2946 explicitly naming the "raw per-event/per-order" → "Pre-aggregate to ONE ROW PER DAY in a CTE" routing.
- Names the mnemonic "the noun in **daily** revenue is a SIGNAL that the window operand must be a daily series" at r07:2953.
- Shows the LEADING CANONICAL daily-CTE-then-RANGE-INTERVAL shape at r07:2955+ (this iter's exact corrected form).
- Has a `DO NOT WRITE` block at r07:2979+ with the EXACT bug the responder produced (windowing raw per-order rows directly).
- States explicitly at r07:2998 "Two independent things are wrong here, NOT one: (1) the FRAME counts rows not days, AND (2) the AVERAGE is over individual order amount values, not over daily SUM(amount) totals."

The Pattern D landing documents the exact failure shape verbatim. The responder cited Pattern D but didn't apply it — this is **responder-drift / findability-under-DECIDE-FIRST**, NOT a resource silence.

**Recommendation for iter692:** DEFAULT NO-OP. Pattern D is bulletproof and re-editing it risks bloat. If a third consecutive Q2-shaped drift appears (i.e., one more iter where the responder cites Pattern D but skips the pre-aggregate), then consider a targeted findability micro-edit — e.g., a one-line keyword stub near the top of r07 ("**Question shape: 'rolling avg of daily revenue from raw orders' → ALWAYS pre-aggregate to one-row-per-day CTE FIRST, then window. See Pattern D LEADING CANONICAL line 2955.**") so the keyword-matching responder lands on the apply-step block rather than the calendar-aware-frame mechanics-only block. But one drift is not yet a pattern — hold.

The Q1 strict-ordering looseness is a separate watch-item; r07:508-526 already has the MATCH_RECOGNIZE canonical. Not a fix target this iter.

---

## Topic checklist updates

- **Common analytical query patterns: aggregations, funnels, cohort, time-series** — Q1 (funnel), Q2 (rolling window), Q3 (CUBE), Q4 (UNNEST) — all touch this. Mixed signal: Q3+Q4 strong-PASS, Q1 mid, Q2 grain-error. Topic remains PASSED but this iter is a soft data point.
- **Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL** — same — PASSED, soft data point.

---

## Dialect verifications (trino.io/docs/current)

- **Q1 CTE-chain funnel** — valid Trino 467 (standard SELECT/CTE/JOIN). MATCH_RECOGNIZE supported in Trino since early versions; r07:508-526 canonical is correct.
- **Q2 RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW** — VALID Trino 467 syntax (supported since Trino 346, March 2021; trino.io/docs/current/functions/window.html). Value-based frame, gap-day correct. **BUT** the grain-mismatch defect lives one layer up at the AGGREGATE INPUT, not in the frame syntax.
- **Q3 CUBE + GROUPING() bitmask** — verified at trino.io/docs/current/functions/aggregate.html. Leftmost arg = MSB; bit SET (=1) when column is rolled up / aggregated away. Bitmask labels 0/1/2/3 = Detail / Region Total / Product Total / Grand Total are correct.
- **Q4 CROSS JOIN UNNEST(arr) WITH ORDINALITY AS t(elem, idx)** — verified at trino.io/docs/current/sql/select.html. Element-first, ordinality-last, 1-based index — exact match.

Sources verified:
- [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html)
- [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html)
- [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html)
- [Trino blog: Introducing new window features (RANGE INTERVAL since 346)](https://trino.io/blog/2021/03/10/introducing-new-window-features.html)
