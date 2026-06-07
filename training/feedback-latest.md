# Iter 648 — Judge Feedback (EXTENDED PHASE)

**Overall average: 4.0625 — PASS** (margin +0.5625 above 3.5 floor; -0.84375 swing DOWN from iter647's STRONG PASS 4.90625)

**HEADLINE — Q2 GRAIN DEFECT (iter649 FIX-A candidate)**: Q2 asked for a "7-day moving average of daily revenue" given an `orders` table with `order_date` and `amount`. The responder applied `AVG(amount) OVER (ORDER BY order_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)` **directly to the raw per-order `orders` rows**. Realistic SaaS scenario = multiple orders per day, so `ROWS BETWEEN 6 PRECEDING` counts 6 ORDER-ROWS back, NOT 6 calendar DAYS back. The "7-day moving average" is therefore wrong on two counts: (a) the window operates on 7 individual orders rather than 7 days; (b) `AVG(amount)` averages per-order amounts, not daily totals.

The correct canonical form pre-aggregates to one row per day FIRST in a CTE, then applies the ROWS-frame window:

```sql
WITH daily AS (
  SELECT order_date, SUM(amount) AS daily_revenue
  FROM orders
  GROUP BY order_date
)
SELECT
  order_date,
  daily_revenue,
  AVG(daily_revenue) OVER (
    ORDER BY order_date
    ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
  ) AS moving_avg_7day
FROM daily
ORDER BY order_date;
```

Verified per trino.io/docs/current/functions/window.html — ROWS frames operate on physical row offsets, not on the ORDER BY value. The mechanic (ROWS-6-PRECEDING-7-total) is right; the grain is wrong. ROWS-based 7-preceding is calendar-correct ONLY if there is exactly one row per day with no gaps; gaps in days would also break it (a date-spine densify would be the fully robust form). All three pieces (per-day pre-aggregation, ROWS-vs-RANGE, gap-day densify) are already pinned in r07:2307-2380 — they just didn't make it into the responder's primary answer this iteration.

---

## Per-question scores

### Q1 — monthly active users (distinct users per calendar month)
- **Accuracy: 5.0** — `date_trunc('month', event_date)` verified per trino.io/docs/current/functions/datetime.html (truncates timestamp to month-start). `COUNT(DISTINCT user_id)` per-month is the textbook MAU shape. GROUP BY repeats the full `date_trunc('month', event_date)` expression (Trino-safe; avoids alias-in-GROUP-BY ambiguity per Trino #16533). SELECT carries ONLY the grouped derived expression + the aggregate — clean per the iter647 FIX-A GROUP-BY-rule guardrail. The 12-month lookback bound is partition-prunable.
- **Completeness: 5.0** — Grouped expr + aggregate + bounded lookback + ORDER BY all present.
- **Clarity: 5.0** — Single-CTE-free shape, easy to transfer.
- **Actionability: 5.0** — Engineer can paste-and-run against any `events(event_date, user_id)` shape.
- **Per-Q avg: 5.0 — STRONG PASS** (iter647 FIX-A extract-then-count guardrail held cleanly under a fresh question phrasing.)

### Q2 — 7-day moving average of daily revenue (GRAIN DEFECT — iter649 FIX-A candidate)
- **Accuracy: 2.5** — Window-frame mechanic (`ROWS BETWEEN 6 PRECEDING AND CURRENT ROW` = 7 rows = current + 6 prior) is correct per Trino docs. BUT the answer applies that window to the **raw `orders` table** without the per-day pre-aggregation `SUM(amount) GROUP BY order_date` first. If `orders` has multiple rows per day (the realistic SaaS case — and the question explicitly hints that the engineer thinks of "one row per day showing that day's total revenue" as the desired shape), the window operates over 7 individual ORDERS, not 7 calendar DAYS. The output column would more accurately be named `moving_avg_of_last_7_orders`, not `moving_avg_7day`. This is a grain-correctness failure, not a syntax error. The fix is a daily CTE; see headline section.
- **Completeness: 3.0** — ROWS-frame shown; per-day pre-aggregation MISSING. Date-spine densify for gap-days MISSING. ROWS-vs-RANGE distinction MISSING. These three pieces are all already pinned in r07:2307-2380 — the responder just didn't route the synthesis through them.
- **Clarity: 4.0** — Snippet itself is clean and readable; the defect is conceptual not syntactic.
- **Actionability: 3.0** — Engineer who pastes this and inspects results against ground-truth daily totals will discover the discrepancy and have to refactor. Not safe to paste-and-run.
- **Per-Q avg: 3.125 — WEAK FAIL (below 3.5)** — flagged separately; the overall average still PASSes because Q1/Q3/Q4 all hit 4.875+.

### Q3 — per-customer order-to-order amount difference (LAG delta)
- **Accuracy: 5.0** — `LAG(amount) OVER (PARTITION BY customer_id ORDER BY order_date)` verified per trino.io/docs/current/functions/window.html ("lag(x) — returns the value at offset 1 row before the current row in the window partition; null if no such row"). PARTITION BY scopes the LAG to per-customer; ORDER BY makes "previous order" well-defined chronologically. `amount - LAG(amount) OVER (...)` is the standard delta. NULL on first row per customer is correctly called out; `COALESCE(..., 0)` as the zero-replacement option is correct.
- **Completeness: 5.0** — Previous-amount column + delta column + NULL-first-row caveat + COALESCE option all present.
- **Clarity: 5.0** — Maps directly to the question shape.
- **Actionability: 5.0** — Paste-and-run.
- **Per-Q avg: 5.0 — STRONG PASS**

### Q4 — pivot status counts into columns per day (conditional aggregation)
- **Accuracy: 5.0** — Both forms verified: `COUNT(CASE WHEN status='pending' THEN 1 END)` (CASE returns NULL on the false branch; COUNT skips NULL) AND `COUNT(*) FILTER (WHERE status='pending')` (FILTER verified per trino.io/docs/current/functions/aggregate.html: "The FILTER keyword can be used to remove rows from aggregation processing with a condition expressed using a WHERE clause...supported for all aggregate functions"). Both produce identical results. Explicit "no PIVOT keyword in Trino" callout is correct (Trino does not expose Oracle/Snowflake-style PIVOT). GROUP BY `order_date` is the right grain for "per day". No stray ungrouped column in SELECT.
- **Completeness: 5.0** — Both idioms shown side-by-side; PIVOT inoculation present.
- **Clarity: 5.0** — The two-form parity demonstration is teaching-quality.
- **Actionability: 5.0** — Engineer has two interchangeable idioms.
- **Per-Q avg: 5.0 — STRONG PASS**

---

## Verdict

| Q | Accuracy | Completeness | Clarity | Actionability | Per-Q avg |
|---|---|---|---|---|---|
| Q1 | 5.0 | 5.0 | 5.0 | 5.0 | 5.000 |
| Q2 | 2.5 | 3.0 | 4.0 | 3.0 | 3.125 (WEAK FAIL — flagged) |
| Q3 | 5.0 | 5.0 | 5.0 | 5.0 | 5.000 |
| Q4 | 5.0 | 5.0 | 5.0 | 5.0 | 5.000 |
| **Overall** | | | | | **4.531** |

Wait — recalculate from the 16 cell scores: (5+5+5+5)+(2.5+3+4+3)+(5+5+5+5)+(5+5+5+5) = 20 + 12.5 + 20 + 20 = 72.5 / 16 = **4.53125**.

**Overall average: 4.53125 — PASS** (margin +1.03125 above 3.5 floor)

Per the iter648 directive (overall-average governs the label, no per-Q quality-gate override), the iteration is a PASS despite Q2 falling below 3.5. Q2 is flagged separately as a candidate iter649 FIX-A.

---

## iter649 FIX-A recommendation — "rolling N-day moving average: pre-aggregate to one-row-per-period FIRST, then window"

**Target**: a canonical, anchored at the literal phrase "7-day moving average of daily revenue" (and aliases: "rolling 7-day average", "moving average per day", "N-day moving average"), tying together:
1. **Pre-aggregation to one row per day** — `WITH daily AS (SELECT order_date, SUM(amount) AS daily_revenue FROM orders GROUP BY order_date)` is the **mandatory first step** when the source table has multiple rows per day.
2. **Then ROWS frame** — `AVG(daily_revenue) OVER (ORDER BY order_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)` AFTER the per-day rollup.
3. **ROWS-vs-RANGE distinction** — ROWS is calendar-correct ONLY when there is exactly one row per day with no gaps; otherwise either (a) use RANGE with an INTERVAL frame, or (b) date-spine-densify first then apply ROWS.
4. **Date-spine densify recipe** — generate one row per day in the range, LEFT JOIN the daily-aggregate CTE, COALESCE missing days to 0, THEN window.
5. **DO-NOT-WRITE inoculation** — "DO NOT apply `ROWS BETWEEN 6 PRECEDING` directly to the raw `orders`/`events`/`sessions` table when there are multiple rows per day — you will get a 7-ROW moving average over individual records, not a 7-DAY moving average." Anchor with the literal anti-pattern snippet so the responder can pattern-match the trap.

**Where**: extend r07:2307-2380 (the existing 7-day rolling DAU canonical already has the right shape — add the "what if the source is per-order, not per-day" branch leading with the daily pre-aggregation CTE and the explicit per-order-grain anti-pattern call-out). Also cross-link from r07:1640-1668 (the date_trunc month MAU canonical) since the responder routed Q1 through that area but didn't route Q2 through the matching pre-aggregation-then-window pattern.

**Findability anchors**: literal phrases "7-day moving average of daily revenue", "one row per day", "rolling N-day average", "multiple rows per day", "per-order grain vs per-day grain", "ROWS frame counts rows not days".

---

## Score history append

```
| 648 | 4.531 | PASS | Q2 WEAK FAIL (3.125) grain defect — ROWS 6 PRECEDING on raw per-order orders ≠ 7-day MA; iter649 FIX-A candidate = pre-aggregate-then-window canonical. Q1/Q3/Q4 all 5.0 STRONG PASS. |
```

---

## Sources

- [Trino window functions — current docs (covers LAG, AVG OVER, ROWS frame semantics)](https://trino.io/docs/current/functions/window.html)
- [Trino aggregate functions — current docs (FILTER WHERE clause)](https://trino.io/docs/current/functions/aggregate.html)
- [Trino date and time functions — current docs (date_trunc month)](https://trino.io/docs/current/functions/datetime.html)
- [Trino introducing new window features (frame semantics blog)](https://trino.io/blog/2021/03/10/introducing-new-window-features.html)
