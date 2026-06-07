# Iter 660 Judge Feedback — 2026-06-08 (EXTENDED PHASE)

**OVERALL: 4.21875 PASS** (margin +0.71875 above 3.5 floor; -0.65625 swing DOWN from iter659's 4.875 — Q2 ORDER BY validity bug drags the iteration; durability-win on dayname-trap-avoidance offsets only partially).

Per-Q: Q1=5.00 / Q2=2.875 / Q3=4.00 / Q4=5.00.

---

## Per-question scoring

### Q1 — extract value by key from a MAP column (NULL on missing)
Answer: `element_at(properties, 'plan') AS plan FROM events`. Stated returns NULL for missing key, no error.

- **Accuracy**: 5 — Verified at trino.io/docs/467/functions/map.html: "Returns value for given `key`, or `NULL` if the key is not contained in the map." This is the docs-correct safe lookup (distinct from `[]` subscript which raises). Correct.
- **Completeness**: 5 — Direct answer; explicitly calls out the NULL-on-missing contract.
- **Clarity**: 5 — Minimal one-liner that mirrors the question shape.
- **Actionability**: 5 — Copy-pasteable; engineer plugs in column + key and ships.
- **Q1 average**: **5.00**

### Q2 — total revenue by weekday WITH the day NAME (Monday..Sunday)
Answer: `format_datetime(CAST(order_date AS timestamp), 'EEEE') AS day_name, SUM(amount) AS total_revenue FROM orders GROUP BY format_datetime(CAST(order_date AS timestamp), 'EEEE') ORDER BY day_of_week(order_date)`. Also mentioned `date_format(...,'%W')`.

- **Accuracy**: 2.5 — DAYNAME-TRAP AVOIDED (durability win): `format_datetime(...,'EEEE')` and `date_format(...,'%W')` are BOTH real Trino 467 functions, both correctly require timestamp (the CAST is right). Verified at trino.io/docs/467/functions/datetime.html — Trino has NO `dayname()` and the responder did not invent one. **BUT the ORDER BY clause has a real, query-breaking bug**: `GROUP BY format_datetime(CAST(order_date AS timestamp), 'EEEE')` does NOT make raw `order_date` available, yet `ORDER BY day_of_week(order_date)` references raw `order_date`. Verified at trino.io/docs/467/sql/select.html + SQL spec: in a GROUP BY query, every non-aggregate ORDER BY expression must be composed of grouping columns, aggregates, or output aliases. This query will fail with "'order_date' must be an aggregate expression or appear in GROUP BY clause". The select-list and weekday-name extraction are correct; only the ORDER BY does not execute. Net: durability win on dayname-avoidance, but a query-breaking ORDER BY ding pulls accuracy down.
- **Completeness**: 3 — Two real alternatives (EEEE + %W) is good. Did not mention that the ORDER BY needs `day_of_week` either added to GROUP BY (and selected) OR wrapped in `min(day_of_week(order_date))` to be valid.
- **Clarity**: 3.5 — Reads cleanly, but a junior who pastes it gets a confusing runtime error.
- **Actionability**: 2.5 — Copy-paste does not run. Engineer hits a runtime error and must self-debug a non-trivial GROUP BY/ORDER BY rule.
- **Q2 average**: **2.875** (< 3.5 — weak; FIX-A candidate)

### Q3 — second-highest order amount per region
Answer: `ROW_NUMBER() OVER (PARTITION BY region ORDER BY amount DESC) AS rn ... WHERE rn = 2`.

- **Accuracy**: 4 — Query executes and returns a defensible "runner-up order per region". Verified at trino.io/docs/467/functions/window.html: ROW_NUMBER assigns unique consecutive numbers; DENSE_RANK groups ties (1,1,2). For "second-highest AMOUNT" with top-ties, `ROW_NUMBER=2` returns the OTHER top-amount row (a duplicate of the max value), NOT the second-distinct amount. DENSE_RANK=2 is the docs-preferred shape for second-distinct-value semantics. The answer is valid as written but not the most-robust reading; tie nuance not called out.
- **Completeness**: 3.5 — Misses the tie-nuance disclosure that the iter643 second-largest/Nth-largest canonical (r23:1014-1097) explicitly carries (DENSE_RANK=2 for second-DISTINCT amount; ROW_NUMBER=2 for literal second row). Question phrasing "second-highest AMOUNT" leans toward DENSE_RANK.
- **Clarity**: 4.5 — Clean window-function form, easy to read.
- **Actionability**: 4 — Engineer can run it; only wrong-but-quiet results when the top amount is tied.
- **Q3 average**: **4.00**

### Q4 — total units sold per product, completed orders only
Answer: `SUM(quantity) FILTER (WHERE status = 'completed') AS units_sold_completed FROM order_items GROUP BY product_id`.

- **Accuracy**: 5 — Verified at trino.io/docs/467/functions/aggregate.html: `FILTER (WHERE ...)` is supported on every aggregate, evaluated per row before aggregation. Conditional aggregation, single pass, GROUP BY product. Docs-correct.
- **Completeness**: 5 — One-pass, zero-group-safe; exact shape the question asks for.
- **Clarity**: 5 — Minimal one-liner, immediately readable.
- **Actionability**: 5 — Copy-paste runs.
- **Q4 average**: **5.00**

---

## Overall computation

| Q | Acc | Comp | Clar | Act | Avg |
|---|-----|------|------|-----|-----|
| Q1 | 5.0 | 5.0 | 5.0 | 5.0 | 5.00 |
| Q2 | 2.5 | 3.0 | 3.5 | 2.5 | 2.875 |
| Q3 | 4.0 | 3.5 | 4.5 | 4.0 | 4.00 |
| Q4 | 5.0 | 5.0 | 5.0 | 5.0 | 5.00 |

**Overall = (5.00 + 2.875 + 4.00 + 5.00) / 4 = 4.21875**

**Verdict: PASS** (4.21875 >= 3.5). Q2 is a weak answer (per-Q < 3.5) — flagged separately; per directive, the overall average governs the PASS/FAIL label.

---

## Iter661 directive

**FIX-A = Q2 ORDER BY validity note at the revenue-by-weekday / day_of_week neighborhood.**

Q2 per-Q (2.875) is the lowest and below 3.5 — name as FIX-A per directive.

Place a short note at the existing day_of_week / format_datetime / weekday-name landing (r07:1347 + r23:395-415 + r27:692 — wherever the weekday-name composition is most reachable by keyword), along the following lines:

> **ORDER BY in a GROUP BY query rule (Trino 467):** every non-aggregate ORDER BY expression must be composed of (a) grouping columns/expressions, (b) aggregate functions, or (c) SELECT-output aliases. Raw columns NOT in the GROUP BY and NOT inside an aggregate cause "must be an aggregate expression or appear in GROUP BY clause".
>
> **For "revenue by weekday NAME ordered Mon..Sun"** the right shapes are:
> ```sql
> -- Option A: GROUP BY the int, derive name in SELECT
> SELECT
>   CASE day_of_week(order_date)
>     WHEN 1 THEN 'Monday' WHEN 2 THEN 'Tuesday' WHEN 3 THEN 'Wednesday'
>     WHEN 4 THEN 'Thursday' WHEN 5 THEN 'Friday' WHEN 6 THEN 'Saturday'
>     WHEN 7 THEN 'Sunday'
>   END AS weekday_name,
>   SUM(amount) AS total_revenue
> FROM orders
> GROUP BY day_of_week(order_date)
> ORDER BY day_of_week(order_date);
>
> -- Option B: format_datetime + min(day_of_week(...)) aggregate-wrap in ORDER BY
> SELECT format_datetime(CAST(order_date AS timestamp), 'EEEE') AS weekday_name,
>        SUM(amount) AS total_revenue
> FROM orders
> GROUP BY format_datetime(CAST(order_date AS timestamp), 'EEEE')
> ORDER BY min(day_of_week(order_date));
> ```
>
> **DO NOT WRITE**: `GROUP BY format_datetime(..., 'EEEE') ... ORDER BY day_of_week(order_date)` — `order_date` is not grouped or aggregated, so Trino raises "must be an aggregate expression or appear in GROUP BY clause". Wrap it in `min()` (or `max()`) since all rows in the group share the same day-of-week int, or GROUP BY `day_of_week(order_date)` too.

Optional secondary nudge (Q3 minor, NOT a FAIL fix): at the iter643 second-largest canonical (r23:1014-1097), if the surface phrase "second-highest AMOUNT per region" is not already in the keyword-anchor block, add it. DENSE_RANK=2 is the more-robust default for value-based "Nth-highest" questions when top-ties matter.

---

## Durability wins this iteration

- **dayname-trap AVOIDED (Q2)**: `format_datetime(..., 'EEEE')` + `date_format(..., '%W')` both real Trino 467; responder did NOT fabricate a `dayname()` function. The iter659 inoculation paid off — confirmed by both the absence of `dayname` strings in resources/ and the responder's selection of two correct alternatives. The ONLY Q2 ding is the ORDER BY scope rule, not the dayname space.
- **element_at NULL-on-missing (Q1)**: pin held; one-liner answer.
- **SUM FILTER conditional aggregation (Q4)**: r23:2057-2122 pin held; one-liner answer.
- **ROW_NUMBER=2 per partition (Q3)**: valid execution; only the tie nuance is missing, not the core mechanism.
