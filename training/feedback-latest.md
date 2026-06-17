# Judge Feedback — iter1040

**Overall: 4.484375 → PASS** (margin +0.984375; overall average governs, no per-Q veto)

Verified BOTH directions vs trino.io/docs/467 + RAW git-tag 467 source (functions/array.md, functions/datetime.md, functions/window.html) + WebSearch (Trino #16984 / AWS re:Post error-class), NOT resources/. Prod stack (Trino 467 + Iceberg + MinIO, Hive Metastore) — all 4 fit; no federation/auth angle.

---

## Per-question scores

### Q1 — running total of revenue BY DAY on raw `orders` (MANY rows/day): **3.5 — INVALID LEAD (2-IN-2 RECURRENCE)**
Acc 2.5 / Comp 4.0 / Clar 4.5 / App 3.0

```sql
SELECT DATE(created_at) AS day,
       SUM(revenue) AS daily_total,
       SUM(revenue) OVER (ORDER BY DATE(created_at) ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_total
FROM orders GROUP BY DATE(created_at) ORDER BY day;
```

**The query does NOT run.** `daily_total = SUM(revenue)` (plain aggregate over the GROUP BY) is correct, and `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` is the right running-total frame. The DEFECT is the cumulative expression: a **bare `SUM(revenue) OVER (...)`** where `revenue` is NEITHER a grouping column NOR wrapped in a GROUP-BY aggregate. Window functions run AFTER aggregation (trino.io/docs/467/functions/window.html: window functions "run after the HAVING clause but before ORDER BY"), so after `GROUP BY DATE(created_at)` the bare column `revenue` no longer exists per-row → Trino raises **"'revenue' must be an aggregate expression or appear in GROUP BY clause"** (error class confirmed via Trino #16984 + AWS re:Post).

**Correct forms** (both taught verbatim in r07):
- Nested aggregate: `SUM(SUM(revenue)) OVER (ORDER BY DATE(created_at) ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` — Pattern A2 (r07 L2763+), the `SUM(SUM(amount)) OVER` window-over-aggregate.
- Pre-aggregate CTE: `WITH daily AS (SELECT DATE(created_at) AS day, SUM(revenue) AS daily_total FROM orders GROUP BY DATE(created_at)) SELECT day, daily_total, SUM(daily_total) OVER (ORDER BY day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_total FROM daily` — r07 L2682-2697 (iter667 BROADEN), the EXACT "per-day running total from row-grain orders" recipe, which ALSO contains the verbatim warning: *"Do NOT try to fix this by writing `SUM(amount) OVER (ORDER BY order_date ROWS ...)` directly on the row-grain `orders` table."*

**RECURRENCE — this is the SECOND occurrence of this exact invalid shape.** iter1038 Q2 was the first (bare single-`SUM(revenue) OVER` beside `GROUP BY order_date`, scored 3.5). iter1039 Q1 dodged it by assuming a pre-aggregated `daily_revenue` table (no GROUP BY → valid running total). iter1040 Q1 puts the broken shape back, now with the GROUP BY explicitly present → 2-in-2 on the real (orders, many-rows-per-day) surface. The resource is COMPLETE and CORRECT on this case (Pattern A / A2 / iter667 BROADEN), so this is a **FINDABILITY / synthesis gap**, not a resource gap — the responder anchors on the base Pattern A example (window over raw rows, no GROUP BY) and bolts a `GROUP BY` onto it without switching to the nested/CTE form.

### Q2 — most recent event per user: **4.8125 CLEAN**
Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75. `ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY changed_at DESC)` then `WHERE rn = 1` in a CTE = canonical top-1-per-group. Window functions are not allowed in `WHERE`, so the CTE wrap is required and correct. Fully sound.

### Q3 — sessions whose `page_views` array contains a pricing URL: **4.8125 CLEAN**
Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75. `contains(page_views, 'https://...')` → boolean membership (array.md verbatim: "Returns true if the array x contains the element"; signature `contains(x, element) -> boolean`); case-sensitive. The case-insensitive variant `contains(transform(page_views, x -> lower(x)), lower('...'))` is sound — `transform(array(T), function(T,U)) -> array(U)` lowercases each element, then `contains` checks membership. Both functions real & verified.

### Q4 — monthly revenue trend, HAVING above $10,000: **4.8125 CLEAN**
Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75. `date_trunc('month', created_at)` valid, returns timestamp truncated to month (datetime.md: `date_trunc('month', TIMESTAMP '2022-10-20 05:10:00') -- 2022-10-01 00:00:00.000`). `GROUP BY DATE_TRUNC('month', created_at)` REPEATS the expression (correct — NOT the SELECT alias, avoids #16533). `HAVING SUM(revenue) > 10000` filters post-aggregation; `> 10000` = strictly above (excludes exactly 10000), matches "above $10,000". WHERE-runs-before / HAVING-runs-after explanation correct. Note: this Q4 demonstrates the responder CORRECTLY uses an aggregate over the GROUP BY in HAVING — contrast with the Q1 window-stage error, confirming the gap is specifically the window-over-aggregate nesting, not GROUP BY aggregates generally.

---

## TICS check
`::` ABSENT all 4. Clean except Q1 (no QUALIFY / false-semi-join / fabricated-fn [ROW_NUMBER/contains/transform/date_trunc all real & verified] / regex-backslash / INTERVAL-quarter-week / OFFSET-before-LIMIT / over-warning / broken-secondary).

---

## Recommendation

**Q1 finding: the bare-`SUM(x) OVER`-beside-`GROUP BY` form is INVALID in 467 (will not run), and this is the 2nd occurrence (iter1038 Q2 first; iter1039 re-probe dodged it by assuming a pre-aggregated table).** This is now a confirmed 2-in-2 on the real row-grain shape.

Classification: **FINDABILITY GAP, not a resource gap.** Grep confirms r07 ALREADY teaches the correct form thoroughly:
- iter667 BROADEN (L2679-2699) — the EXACT "per-day running total from row-grain orders, many rows per day" CTE recipe + the verbatim "Do NOT write `SUM(amount) OVER (...)` directly on the row-grain `orders` table" warning.
- Pattern A2 (L2763+) — `GROUP BY` + `SUM(SUM(x)) OVER` window-over-aggregate canonical + GROUP BY rules anchor + DO-NOT-WRITE matrix.

The responder is anchoring on the BASE Pattern A example (L2554-2568: window over raw `daily_revenue` rows, NO GROUP BY) and bolting a `GROUP BY` onto it without promoting to the nested/CTE form. The iter667 BROADEN guard and Pattern A2 live ~120-200 lines BELOW Pattern A, so the keyword-matching Haiku responder grabs Pattern A first and never reaches the guard.

**Recommend a LIGHT FIX-A: a prominent INLINE guard at Pattern A (immediately after the L2554-2568 base example, before the ROWS-vs-RANGE digression)** with the exact router cue: *"MANY rows per grouping key (e.g. raw `orders`, many orders per day) and you want a running total BY that key? Do NOT write `SUM(x) OVER (...)` beside a `GROUP BY` — `x` is not a grouping column and the window stage runs after aggregation, so Trino errors 'must be an aggregate expression or appear in GROUP BY clause'. Pre-aggregate in a CTE first (see iter667 BROADEN below) OR nest as `SUM(SUM(x)) OVER (...)` (see Pattern A2 below)."* Pull the guard UP to Pattern A so the responder hits it on the first keyword match, with forward-links to the two existing correct recipes. This is additive (no reconcile needed — existing content is correct); it closes the findability gap that the deep-buried guards aren't reaching the responder.

If the responder STILL relapses after the guard is hoisted, reclassify as a Haiku synthesis ceiling (can find the recipe but can't assemble it on a novel domain) and stop churning.

No other action: Q2/Q3/Q4 all clean and resolved in the responder's favor. Do NOT bump state.json (already 1040; orchestrator commits).
