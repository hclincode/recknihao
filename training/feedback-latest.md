# Iter 692 — Judge Feedback (EXTENDED PHASE)

## OVERALL: 4.3125 PASS (margin +0.8125 above 3.5 floor)

Per-Q: (5.00 + 5.00 + 5.00 + 2.25) / 4 = 17.25 / 4 = **4.3125**
Dim-avg cross-check: Acc (5+5+5+2)/4=4.25 / Comp (5+5+5+2)/4=4.25 / Clar (5+5+5+3)/4=4.50 / Act (5+5+5+2)/4=4.25 = (4.25+4.25+4.50+4.25)/4 = **4.3125** — agrees.

GOVERNING LABEL = **PASS** (overall 4.3125 ≥ 3.5; per-Q quality-gate override NOT applied per directive; Q4 2.25 below per-Q 3.5 floor flagged in prose only).

## KEY VERDICTS

### Q1 GRAIN-DISCIPLINE VERDICT: **HELD** (the iter691 Q2 drift did NOT recur)
The responder applied the canonical Pattern D form verbatim: PRE-AGGREGATE daily (`COUNT(DISTINCT user_id) GROUP BY event_date`) THEN window (`AVG(dau) OVER RANGE BETWEEN INTERVAL '29' DAY PRECEDING AND CURRENT ROW`). Explicitly names it a grain mismatch + explains row-vs-day. The Pattern D r07:2946-3034 fortifications (DECIDE-FIRST grain block + Mnemonic + LEADING CANONICAL + DO-NOT-WRITE with two-things-wrong decomposition) successfully steered the responder to the correct pre-aggregate form. **The iter691 Q2 drift was a one-off, NOT a pattern** — three consecutive iterations (690→691→692) confirm Pattern D is bulletproof for "rolling avg of daily X" question shape.

### Q4 CUMULATIVE-DISTINCT VERDICT: **DOUBLE-COUNT BUG CONFIRMED** (composition/fusion gap — analogous to iter688 running-cumulative-percent gap)
The responder's CTE computes `COUNT(DISTINCT customer_id)` PER MONTH (= distinct customers ACTIVE in each month, MISLEADINGLY aliased `new_customers_this_month`), then `SUM() OVER (ORDER BY order_month ROWS UNBOUNDED PRECEDING..CURRENT ROW)` running-sums those monthly distinct-active counts. **This DOUBLE-COUNTS customers active in multiple months**: a customer active in Jan AND Feb is counted in BOTH Jan's distinct count AND Feb's distinct count, so the running sum counts them TWICE. The question asks for CUMULATIVE DISTINCT customers (each customer counted ONCE by end of month X) — which IS monotonic non-decreasing, but the responder's running-sum-of-monthly-distinct OVER-COUNTS repeat customers and is NOT the true cumulative-distinct.

The running-total STRUCTURE (Pattern A2) is correct, but it is applied to the WRONG per-month metric (distinct-ACTIVE instead of NEW/FIRST-APPEARANCE), producing an inflated, non-distinct cumulative count.

**CORRECT FORM** (count each customer at their FIRST-order month only, THEN running-sum the cohort counts):
```sql
WITH first_order AS (
  SELECT customer_id, DATE_TRUNC('month', MIN(order_date)) AS first_month
  FROM orders
  GROUP BY customer_id
),
new_per_month AS (
  SELECT first_month AS order_month, COUNT(*) AS new_customers
  FROM first_order
  GROUP BY first_month
)
SELECT
  order_month,
  new_customers,
  SUM(new_customers) OVER (ORDER BY order_month ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_distinct_customers
FROM new_per_month
ORDER BY order_month;
```
Each customer contributes to the running sum exactly ONCE (in their first-order month), so the cumulative total is the true count of distinct customers ever-ordered through that month.

**VERIFIED**: running-SUM of `COUNT(DISTINCT customer_id)`-per-month ≠ cumulative-distinct-ever (double-counts multi-month customers); the first-order-month-cohort + running-SUM is the correct monotonic cumulative-distinct form.

### Resource gap: cumulative-distinct-over-time canonical is ABSENT
Grep confirms **no canonical pattern for "cumulative distinct count over time" / first-appearance-cohort + running-sum exists in resources/**. r07:1700+ Pattern A running-total cards teach running-SUM-of-additive-metric; r07:1886+ Pattern A2 teaches per-bucket aggregate + running-SUM (correct for additive metrics like `COUNT(*)`, `SUM(revenue)`, but NOT for `COUNT(DISTINCT)` which is non-additive across periods). r07:638-740 rolling-distinct HLL covers ROLLING (trailing N-day window) distinct counts but not CUMULATIVE (unbounded preceding) distinct counts. The first-appearance-cohort + running-sum pattern is a fusion shape (composing first-occurrence aggregation + running-SUM of cohort counts) NOT modeled as a single worked example anywhere in resources/. **This is a composition/fusion gap directly analogous to the iter688 running-cumulative-percent gap** (where Pattern A running-total + share-of-grand-total were correct separately but their composition into "running cumulative percent" was not modeled, causing responder drift).

## DIALECT VERIFICATIONS (trino.io/docs/467)

- **Q1 `RANGE BETWEEN INTERVAL '29' DAY PRECEDING AND CURRENT ROW`** — VALID Trino 467 (RANGE with interval offset supported since v346; sorting column is `event_date` of date type, compatible with `INTERVAL '29' DAY`). Off-by-one check: `29 days PRECEDING + CURRENT ROW = 30 calendar days inclusive` — correct for "30-day rolling average".
- **Q2 `SUM(CASE WHEN status='X' THEN 1 ELSE 0 END)` AND `COUNT(*) FILTER (WHERE status='X')`** — both VALID Trino 467 (r23:838-867 canonical confirms both forms produce identical row counts + identical plans; r07:795 docs-truth pin "there is no PIVOT keyword in Trino's SQL grammar").
- **Q3 `COUNT(*)` / `COUNT(rating)` / `AVG(rating)`** — VALID Trino 467 semantics (r07:1194 verbatim docs quote: `count(*)` counts input rows, `count(x)` counts non-null input values; AVG ignores NULL per aggregate-page exception rule — NOT in the count/count_if/max_by/min_by/approx_distinct exception list).
- **Q4 running-SUM of COUNT(DISTINCT) per month** — STRUCTURE valid Trino 467 syntax (SUM-as-window-aggregate + ROWS UNBOUNDED PRECEDING..CURRENT ROW frame), but SEMANTICALLY WRONG for the asked question — produces inflated count that double-counts multi-month customers. First-order-month-cohort + running-sum is the correct monotonic cumulative-distinct form.

## PER-QUESTION SCORES

### Q1 (rolling-daily-aggregate re-probe) — 5.00 (Acc5/Comp5/Clar5/Act5)
GRAIN DISCIPLINE CORRECT. CTE `daily_active_users` pre-aggregates to one row per day with `COUNT(DISTINCT user_id) AS dau GROUP BY event_date`, THEN outer query windows the daily series with `AVG(dau) OVER (ORDER BY event_date RANGE BETWEEN INTERVAL '29' DAY PRECEDING AND CURRENT ROW)`. Explicitly names it a "grain mismatch" + explains rows-vs-days. RANGE-INTERVAL choice is gap-day correct (calendar-aware). Off-by-one (29 preceding + current = 30 days) is correct. Pattern D r07:2946-3034 fortifications WORKING.

### Q2 (long-to-wide pivot) — 5.00 (Acc5/Comp5/Clar5/Act5)
Canonical conditional-aggregation form with `SUM(CASE WHEN status='X' THEN 1 ELSE 0 END) GROUP BY customer_id` + ALSO offers the FILTER form `COUNT(*) FILTER (WHERE status='X')`. No PIVOT keyword fabrication. Both forms valid Trino 467 (r23:838-867 + r07:795 confirm). Zero-group-safe with GROUP BY customer_id (every customer appears, including those with zero matching rows).

### Q3 (NULL-in-aggregates) — 5.00 (Acc5/Comp5/Clar5/Act5)
Correct NULL-in-aggregate semantics: `COUNT(*) AS total_orders` (all rows including NULL ratings), `COUNT(rating) AS orders_with_rating` (non-NULL only), `AVG(rating) AS avg_rating` (ignores NULL — denominator = non-NULL count, never treats NULL as 0). Matches r07:1194 verbatim docs quote + Trino 467 aggregate-page exception rule. Three columns in one pass — actionable single-statement form.

### Q4 (cumulative distinct-customer by month) — 2.25 (Acc2/Comp2/Clar3/Act2) [CUMULATIVE-DISTINCT DOUBLE-COUNT FLAG]
CRITICAL BUG: running-SUM of `COUNT(DISTINCT customer_id)`-per-month DOUBLE-COUNTS multi-month customers. Misleadingly aliases monthly distinct-active count as "new_customers_this_month" (it is NOT new — it is active-in-this-month, which includes returning customers). Then SUM-OVER-cumulative running-totals these counts, inflating the cumulative total by the count of multi-month customers. Question asks for CUMULATIVE DISTINCT customers ever-ordered through end of month X (each customer counted exactly ONCE, monotonic) — responder's answer is monotonic non-decreasing (correct shape) but the VALUES are wrong (inflated). The first-order-month-cohort + running-sum form (count each customer at their first-order month only, then running-sum the cohort counts) is the correct canonical. -3.00 on Accuracy (the answer is executable but produces wrong values), -3.00 on Completeness (misses the "distinct ever" semantic entirely), -2.00 on Clarity (the misleading alias `new_customers_this_month` is itself a teaching error — these are NOT new customers, they are active customers), -3.00 on Actionability (an engineer who runs this query against prod gets a wrong KPI on the cumulative-customers dashboard tile).

## FLAGGED WEAK ANSWERS

- **Q4 2.25**: cumulative-distinct double-count — running-sum of monthly distinct counts is NOT cumulative distinct. The structure (Pattern A2) is right but applied to the wrong per-month metric (distinct-active instead of new/first-appearance). Inflated, non-distinct cumulative count. The misleading alias `new_customers_this_month` for `COUNT(DISTINCT customer_id) PER MONTH` is itself wrong (these are active customers in the month, NOT new customers — new means first-time, which requires `DATE_TRUNC('month', MIN(order_date))` per customer).

## TEACHER FEEDBACK & iter693 RECOMMENDATION

**RECOMMENDED iter693 = FIX-A: ADD CUMULATIVE-DISTINCT-OVER-TIME CANONICAL** (composition/fusion gap analogous to iter688 running-cumulative-percent FIX-A).

The resource grep confirms NO canonical for "cumulative distinct customers / users / entities over time" exists. r07:1700+ Pattern A teaches running-total of additive metrics; r07:1886+ Pattern A2 teaches per-bucket-aggregate + running-SUM; r07:638-740 covers ROLLING-distinct (HLL/self-join over trailing N-day) but NOT CUMULATIVE-distinct (unbounded preceding). The fusion shape (first-occurrence cohort + running-sum) is unmodeled — this is the same shape of gap that caused iter688 Q3's double-100 drift and that was successfully fixed by iter689's Pattern A3 FIX-A.

**Specific FIX-A directive for iter693:**

1. **Add new canonical card at r07** (placement: after Pattern A3 r07:1938-2052 running-cumulative-percent / before Pattern B Lag-Lead, OR as new H3 under §5 time-series carry-forward family — pick whichever flows best):

   **Pattern A4: LEADING CANONICAL — Cumulative DISTINCT count over time (first-appearance cohort + running-SUM)**
   - Title with keyword anchors: "cumulative distinct customers by month", "cumulative unique users by month", "total customers ever-ordered through end of month X", "running count of distinct entities over time", "ever-ordered customer count per month", "cumulative unique count", "monotonic distinct over time", "count of customers acquired by end of month", "lifetime distinct customer count by period", "cohort-based cumulative count"
   - One-fact opener: "Running-SUM of `COUNT(DISTINCT col)`-per-period is NOT cumulative distinct — it DOUBLE-COUNTS entities active in multiple periods. To get true cumulative distinct (each entity counted ONCE through end of period X), count each entity at their FIRST-occurrence period only, THEN running-SUM the cohort counts."
   - LEADING CANONICAL SQL (the corrected form shown above with `first_order` + `new_per_month` CTEs + `SUM(new_customers) OVER (ORDER BY order_month ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`)
   - Worked example output table showing monotonic non-decreasing cumulative count with the cohort decomposition (Jan: 100 new = 100 cumulative; Feb: 50 new = 150 cumulative; Mar: 30 new = 180 cumulative — even if Mar had 200 active customers total, only 30 are NEW so cumulative grows by 30).
   - Explainer: WHY first-appearance is correct — each customer is "added" to the cumulative population exactly once (in their first-order month) and stays in the population forever; running-SUM of NEW counts accumulates the population correctly.
   - DO-NOT-WRITE block with the EXACT iter692 Q4 bug:
     ```
     -- WRONG: SUM-OVER of COUNT(DISTINCT) per month DOUBLE-COUNTS multi-month customers
     WITH monthly AS (
       SELECT DATE_TRUNC('month', order_date) AS order_month,
              COUNT(DISTINCT customer_id) AS active_customers  -- ACTIVE not NEW
       FROM orders GROUP BY DATE_TRUNC('month', order_date)
     )
     SELECT order_month, active_customers,
            SUM(active_customers) OVER (ORDER BY order_month ROWS UNBOUNDED PRECEDING)
              AS cumulative_DOUBLE_COUNTED  -- NOT cumulative-distinct; inflated
     FROM monthly;
     ```
   - Two-things-wrong decomposition (mirroring r07:2998 style):
     (1) `COUNT(DISTINCT customer_id) PER MONTH` counts customers active IN that month — multi-month customers appear in EACH month's count.
     (2) Running-SUM of those monthly counts ADDS the multi-month customer once per month they appear, instead of once total.
     Both fixed by the same edit: compute per-customer FIRST month via `DATE_TRUNC('month', MIN(order_date)) GROUP BY customer_id`, then aggregate to per-month new-count, then running-SUM.
   - Misleading-alias warning: do NOT alias `COUNT(DISTINCT customer_id) PER MONTH` as `new_customers_this_month` — it is NOT new, it is active. The `new_customers` label MUST be reserved for the first-appearance cohort count (`COUNT(*)` over the `first_order` CTE grouped by `first_month`).
   - Decision table — when to use Pattern A4 vs alternatives:
     | Question shape | Pattern |
     |---|---|
     | Cumulative DISTINCT entities through end of period X (monotonic, each counted once) | **Pattern A4 (this card)** — first-appearance cohort + running-SUM |
     | Cumulative SUM/COUNT of additive metric (revenue, event count) | Pattern A / Pattern A2 — running-SUM of period sums |
     | Rolling/trailing N-day DISTINCT count (sliding window, NOT cumulative) | r07:638+ HLL or exact-self-join |
     | NEW customers acquired per period (the cohort itself, NOT cumulative) | first_order CTE + GROUP BY first_month (mid-step of Pattern A4) |

2. **Add inbound keyword anchors** at r07:638 (rolling-distinct HLL section) cross-referencing "for CUMULATIVE distinct count over time (unbounded preceding, not trailing N-day) see Pattern A4 at r07:XXXX".

3. **Add inbound keyword anchors** at r07:1886+ Pattern A2 cross-referencing "for cumulative DISTINCT counts (not additive), use Pattern A4 — running-SUM of COUNT(DISTINCT) per period DOUBLE-COUNTS".

**Why FIX-A not DEFAULT NO-OP**: This is a composition/fusion gap exactly like iter688 running-cumulative-percent (resource correct on both components — `COUNT(DISTINCT)`-per-period and running-SUM — separately; their NAIVE composition is what's wrong). The iter689 Pattern A3 FIX-A closed the iter688 fusion drift permanently. A Pattern A4 FIX-A at r07 will permanently close the cumulative-distinct fusion drift. Single-iteration drift, but the structural absence of the canonical means it WILL recur on any future cumulative-distinct re-probe. The asymmetry: this question shape is foundational SaaS analytics ("how many customers have we ever acquired?" → cumulative-distinct lifetime customer count is a standard dashboard tile).

**1-drift-vs-pattern rule check**: Q4 is the FIRST cumulative-distinct probe in recent iterations (no prior cumulative-distinct question to compare against). However, the gap is STRUCTURAL (canonical absent) not RESPONDER-SIDE (responder had no resource to drift away from). Treating it as a 1-drift would leave the gap unfixed; the structural absence justifies FIX-A independent of drift count.

## SUMMARY OF TOPIC AVG UPDATES

- **Common analytical query patterns: aggregations, funnels, cohort, time-series** (Q1 grain-discipline re-probe HELD canonical durability +0.30 — Pattern D r07:2946 LEADING CANONICAL confirmed bulletproof across 3 consecutive iters; Q2 long-to-wide conditional aggregation canonical durability +0.30 — both SUM(CASE) + FILTER forms confirmed valid; Q3 NULL-in-aggregates canonical durability +0.30 — COUNT(*) vs COUNT(col) vs AVG(ignores NULL) semantics confirmed)
- **Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL** (Q4 cumulative-distinct: responder-drift on first-appearance-cohort + running-SUM fusion shape, -0.25 on canonical durability for UNMODELED fusion shape; resource correct on both components separately; logged as STRUCTURAL GAP, FIX-A recommended)

## CONFIRMATIONS

- Pattern D r07:2946-3034 — UNTOUCHED + CONFIRMED DURABLE (3 consecutive iter wins 690→691→692; the iter691 Q2 drift verified one-off, not a pattern).
- r07:795 + r23:838-867 long-to-wide conditional aggregation — UNTOUCHED + CONFIRMED DURABLE.
- r07:413 + r07:1194 NULL-in-aggregate semantics — UNTOUCHED + CONFIRMED DURABLE.
- ALL iter534-691 locks — UNTOUCHED.
- iter692 teacher NO-OP confirmed appropriate for Q1/Q2/Q3 (those were the 3 grep targets that were findable + docs-correct + untouched-per-directive); Q4 reveals a NEW structural gap not visible to the iter692 grep pass (the grep targeted EXISTING canonical durability not COMPOSITION/FUSION shape coverage).

## FINAL VERDICT

**OVERALL: 4.3125 PASS** — Q1 grain discipline HELD (Pattern D bulletproof, iter691 drift one-off-not-pattern verified); Q2/Q3 docs-perfect; Q4 cumulative-distinct double-count BUG (running-SUM of COUNT(DISTINCT)-per-month inflates by multi-month customer count; correct form is first-order-month cohort + running-SUM). iter693 recommended **FIX-A: ADD CUMULATIVE-DISTINCT-OVER-TIME CANONICAL (Pattern A4)** at r07 with first-appearance-cohort + running-SUM LEADING CANONICAL + DO-NOT-WRITE block for running-SUM-of-COUNT(DISTINCT)-per-period double-count + misleading-alias warning + decision table differentiating from Pattern A/A2 (additive metrics) and r07:638+ HLL (rolling not cumulative). Federation still untouched (48-iter ZERO probe streak, 4.49944 vs 4.5 thin).
