# Iter 641 — Judge Feedback (EXTENDED PHASE)

**Overall: 4.6875 PASS** (margin +1.1875 above 3.5 floor; +0.4375 swing from iter640's 4.25).
Per-Q averages: Q1 = 5.0, Q2 = 4.875, Q3 = 4.875, Q4 = 5.0. Governing label = PASS (overall avg 4.6875 >= 3.5; no per-Q gate override per directive). All per-Q avgs comfortably clear the 3.5 floor.

---

## Per-question scores

### Q1 — Average days a ticket stayed open (FIX-A re-probe: days-between-two-dates)
- Accuracy: 5 | Completeness: 5 | Clarity: 5 | Actionability: 5
- **Per-Q avg: 5.0 — STRONG PASS**

**iter641 FIX-A VALIDATION — LANDED CLEAN on first re-probe.**

The new r23 days-between-two-dates canonical (inserted between r23:1098 and old r23:1100, immediately after the completed-age `date_diff('year',...)` block) was reached and applied correctly:
- Used `date_diff('day', created_at, closed_at)` for the day count — **NO date-minus-date arithmetic attempted**. The iter640 A2 bug #1 (`CAST(first_purchase_date - signup_date AS bigint)`) class is INOCULATED.
- Argument order correct: `created_at` (earlier) in arg2, `closed_at` (later) in arg3 — result is positive bigint as expected.
- Subquery form projects `days_open` IN the inner SELECT before the outer `AVG(days_open)` references it — **column-scope discipline clean**. The iter640 A2 bug #2 (undefined `days_to_purchase` column in outer SELECT) class is INOCULATED.
- Single-query form `AVG(date_diff('day', created_at, closed_at)) WHERE closed_at IS NOT NULL` is equivalent and also correct.
- Defensive `WHERE closed_at IS NOT NULL` guard included in both forms.

**Verified via WebFetch trino.io/docs/467/functions/datetime.html**: `date_diff(unit, timestamp1, timestamp2) -> bigint`, returns `timestamp2 - timestamp1` (positive when timestamp2 is later — confirms the responder's arg-order claim). **Verified trino.io/docs/467/functions/aggregate.html**: `AVG` over bigint is valid (returns double). Both forms parse and execute under Trino 467 dialect.

### Q2 — Percentage of orders with NULL shipping_address (data-quality null-rate)
- Accuracy: 5 | Completeness: 4.5 | Clarity: 5 | Actionability: 5
- **Per-Q avg: 4.875 — STRONG PASS**

`ROUND(100.0 * COUNT(*) FILTER (WHERE shipping_address IS NULL) / COUNT(*), 2)` is the canonical Trino null-rate idiom.
- `COUNT(*) FILTER (WHERE col IS NULL)` valid Trino 467 (verified aggregate.html: FILTER keyword "supported for all aggregate functions"; "removes rows from aggregation processing with a condition").
- `100.0 *` decimal literal forces float division — avoids the integer-truncation-to-0 trap that plagues null-rate queries written without it.
- `ROUND(..., 2)` to 2 decimal places is a sensible display choice.
- `COUNT(*)` denominator is correct (total rows, including the NULLs in the numerator) — null-rate semantics correct.
- Minor: `count_if(shipping_address IS NULL)` would be a cleaner equivalent (one fewer FILTER token) — **NOT penalized** per directive; FILTER form is fine and arguably more general.
- Small completeness deduction: did not flag optional zero-rows divide-by-zero via NULLIF; in practice `orders` having 0 rows is a non-concern for this question.

### Q3 — Top-spending customer per region (top-1-per-group durability re-probe)
- Accuracy: 5 | Completeness: 4.5 | Clarity: 5 | Actionability: 5
- **Per-Q avg: 4.875 — STRONG PASS**

ROW_NUMBER() OVER (PARTITION BY c.region ORDER BY SUM(o.spend) DESC) AS rn over a GROUP BY c.region, o.customer_id subquery, then outer WHERE rn = 1. Canonical top-1-per-group form.
- Window functions run AFTER aggregation in the same SELECT (verified window.html: "run after the HAVING clause but before the ORDER BY clause"), so `ORDER BY SUM(o.spend) DESC` inside OVER is valid alongside `GROUP BY c.region, o.customer_id` — no window-in-aggregate dialect violation.
- Outer `WHERE rn = 1` references `rn` as a projected column from the subquery — **NOT a window-in-WHERE violation**. This is the correct subquery-wrap pattern for filtering window results.
- max_by(customer_id, total_spend) GROUP BY region would be a cleaner one-pass alternative — **NOT penalized** per directive; ROW_NUMBER is correct and idiomatic.
- Small completeness deduction: tie-breaking at rn=1 on equal SUM(o.spend) not addressed; question did not ask, so minor only.

### Q4 — Weekday vs weekend order counts (dayname-fabrication trap probe)
- Accuracy: 5 | Completeness: 5 | Clarity: 5 | Actionability: 5
- **Per-Q avg: 5.0 — STRONG PASS**

**DAYNAME-FABRICATION TRAP DURABILITY WIN — AVOIDED AGAIN.**
- Used `day_of_week(created_at)` — **NO fabricated `dayname()`**. Verified trino.io/docs/467/functions/datetime.html: `dayname()` does NOT exist in Trino 467; `day_of_week(x) -> bigint` returns `1` (Monday) to `7` (Sunday) ISO numbering.
- `IN (6, 7)` = Saturday, Sunday = weekend is correct under the ISO numbering (Mon=1..Sun=7) — verified.
- CASE form `CASE WHEN day_of_week(created_at) IN (6,7) THEN 'Weekend' ELSE 'Weekday' END` + `COUNT(*) GROUP BY` repeating the CASE expression (NOT the alias) is the correct Trino GROUP BY pattern (Trino GROUP BY does not allow output-alias references — must repeat the expression or use positional ordinal).
- FILTER form `COUNT(*) FILTER (WHERE day_of_week(created_at) NOT IN (6,7)) AS weekday_orders, COUNT(*) FILTER (WHERE day_of_week(created_at) IN (6,7)) AS weekend_orders` is a clean single-row alternative.
- Both forms answer the question completely.

Multi-iteration durability signal: dayname trap has now survived multiple phrasings (revenue by day-of-week, weekend bookings, weekday breakdown, etc.) without recurrence.

---

## Overall computation

Per-Q method: (5.0 + 4.875 + 4.875 + 5.0) / 4 = **4.6875**
Dim-avg cross-check: Acc(5+5+5+5)/4=5.0 / Comp(5+4.5+4.5+5)/4=4.75 / Clar(5+5+5+5)/4=5.0 / Act(5+5+5+5)/4=5.0 = (5.0+4.75+5.0+5.0)/4 = 4.9375; per-Q-avg method governs per prior iterations.

**GOVERNING LABEL = PASS** (overall avg 4.6875 >= 3.5; no per-Q gate override per directive). No per-Q below 3.5 — no FIX-A candidate.

---

## FIX-A landing summary (iter641 PRIMARY directive)

**iter641 FIX-A — days-between-two-dates canonical at r23 (between r23:1098 and old r23:1100) — LANDED CLEAN on first re-probe.**

Routing successful:
1. Responder reached `date_diff('day', earlier, later)` for integer day count — no date-minus-date arithmetic.
2. Subquery form projected `days_open` as a named CTE/subquery column BEFORE the outer `AVG(days_open)` referenced it — column-scope discipline applied.
3. Both subquery and single-query forms presented; both valid Trino 467.

iter640 Q2 double-bug class CLOSED. Keyword anchors (`days a ticket stays open`, `days between two dates`, `tenure in days`, etc.) successfully routed Haiku to the new r23 canonical adjacent to the completed-age `date_diff('year',...)` block.

---

## iter642 directive: DEFAULT NO-OP / DURABILITY-BREADTH

Per the directive: "if any per-Q avg < 3.5, name the lowest as iter642 FIX-A; else recommend DEFAULT NO-OP/durability-breadth." Lowest per-Q is 4.875 — no FIX-A candidate.

**Recommended iter642 plan:**
- **PRIMARY**: DEFAULT NO-OP. Do not edit r23 days-between canonical (just landed). Do not edit r07 Pattern B2 period-total YoY/QoQ ratio sub-canonical (iter640 landed). Do not edit r07 §1a.2A listagg/array_join varchar-CAST guardrail (iter639 landed).
- **SECONDARY (durability-breadth, optional)**: re-probe under-tested durable classes —
  - **Federation** row at 4.49944/310 stale (311th consecutive non-probe). Consider one federation question on a bulletproofed angle (e.g., predicate pushdown to PostgreSQL, JWT auth pass-through limitations, `iceberg.<schema>.<table>` vs `postgresql.<schema>.<table>` cross-catalog join basics).
  - **iter640 FIX-B active-every-N-FULL-months-bounded-window** canonical NOT YET probed — re-probe "active in last 3 FULL calendar months" phrasing to confirm the upper-bound `< date_trunc('month', current_date)` anchor lands.
  - **Days-between class re-probe at a different anchor phrasing** — e.g., "time to first purchase in days", "tenure in days", "days since last login", "elapsed days from event A to event B" to confirm keyword breadth of the new r23 canonical beyond "days a ticket stays open".
  - **Dayname trap re-probe** — e.g., "revenue by day of week with day name labels" — to confirm CASE-WHEN expansion idiom (1->'Monday'...7->'Sunday') holds when day names are required in output, not just weekend/weekday classification.
- **DO NOT**: touch r22 §13.x federation guardrails (4.49944/310 thin); rewrite locks iter534-641; add `::`-casts (iter571 PIN), QUALIFY, RLIKE (iter623 ban), PERCENTILE_CONT/MEDIAN (iter611 ban), EXTRACT(EPOCH) (iter562 ban), fabricated dayname()/initcap, DISTINCT ON (iter634 ban), date-minus-date arithmetic; bump training/state.json (per directive — already 641); git commit/push beyond appending the rubric line.

---

## Meta-note

**Pattern iter640 -> iter641 closes the days-between-two-dates defect class on first re-probe** — a textbook FIX-A landing. The double-bug pattern in iter640 Q2 (date-arithmetic dialect violation + CTE column-scope error) was inoculated by a single well-placed canonical at r23 with both DO-NOT-WRITE examples + the projection-in-CTE-first rule + the LATER-date-in-arg3 callout.

Q4 dayname-fabrication continues to hold across phrasings — this trap has now survived multiple iterations without recurrence; the durability win is structural.

Q2 null-rate `COUNT(*) FILTER (WHERE ... IS NULL) / COUNT(*)` and Q3 `ROW_NUMBER() OVER (PARTITION BY ... ORDER BY SUM(...) DESC)` + outer `WHERE rn = 1` are both canonical-shape clean — these classes are durable.

**Overall PASS margin +1.1875** is the healthiest in recent iterations (+0.4375 swing from iter640's 4.25). Durability via breadth-elsewhere is paying off. Federation row at 4.49944/310 remains untouched for 311th consecutive non-probe iter — consider a re-probe in iter642 if any bulletproofed angle is available.

**OVERALL: 4.6875 PASS — Q1 FIX-A days-between-two-dates LANDED CLEAN (iter640 Q2 double-bug class CLOSED); Q4 dayname trap durability win continues; Q2 null-rate and Q3 ROW_NUMBER-top-1 both canonical-clean; iter642 = DEFAULT NO-OP / durability-breadth (federation re-probe candidate, FIX-B active-every-N-months not yet probed, days-between keyword-breadth re-probe).**
