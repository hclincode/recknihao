# Judge Feedback — iter904 (NO-OP durability sweep, but ONE Q1 DEFECT)

**Overall: 4.56 PASS** (per-Q 3.25 / 5.00 / 5.00 / 5.00 = 18.25 / 4 = 4.5625; margin +1.06 over the 3.5 bar). Overall average governs — no per-Q veto. Do NOT bump `training/state.json` (already passed).

Federation (4.49944/310) was NOT probed this sweep — that row is UNCHANGED and remains the only un-passed topic.

PIN Trino 467. All dialect facts verified vs trino.io/docs/467 (window/select/datetime/aggregate .html) + Trino error-message family via WebFetch/WebSearch 2026-06-10.

---

## Q1 WINDOW-FUNCTION-IN-WHERE VERDICT — CONFIRMED DEFECT in the FIRST query; the SECOND (CTE) query is CORRECT

The run-prompt's central concern is confirmed.

**(a) A window function (`LAG(...) OVER (...)`) in the WHERE clause is ILLEGAL in Trino 467.** VERIFIED vs trino.io/docs/467:
- `window.html`: window functions "run after the `HAVING` clause but before the `ORDER BY` clause" — i.e. they evaluate AFTER WHERE filtering, so a window function cannot appear in WHERE.
- `select.html`: window functions "are limited to SELECT and ORDER BY contexts only"; WHERE runs before windows are computed.
- The Trino analyzer rejects this with an error in the "WHERE clause cannot contain aggregations, window functions or grouping operations" family (analyzer rejection / `mismatched input 'OVER'`).

The FIRST query's `WHERE LAG(current_price) OVER (PARTITION BY product_id ORDER BY price_date) IS NOT NULL` is therefore a **genuine DIALECT DEFECT — it would not run.**

**(b) The SELECT alias `price_jump` in `ORDER BY ABS(price_jump)` is FINE.** VERIFIED `select.html`: output aliases ARE referenceable in ORDER BY (unlike WHERE / GROUP BY-by-alias caveats). So the ORDER BY in the first query is not the problem — only the window-fn-in-WHERE is.

**(c) The SECOND query (CTE) is fully CORRECT.** `WITH price_changes AS (... LAG(...) ... AS price_jump) SELECT ... WHERE price_jump IS NOT NULL ORDER BY ABS(price_jump) DESC LIMIT 1`: here `price_jump` is a REAL materialized CTE column, so `WHERE price_jump IS NOT NULL` is legal (filtering a CTE column, NOT a same-level SELECT alias and NOT a window function). LAG signature `lag(x[, offset[, default]])` confirmed; `ABS` + `DESC` + `LIMIT 1` correct for "biggest single jump". This query returns the right answer and runs.

**Q1 scoring (partial credit, NOT zero — the correct CTE IS present):**
- Accuracy **2.5** — the lead query is unrunnable (window-fn-in-WHERE); the CTE is correct.
- Completeness **4.0** — a correct, complete answer to the question is delivered (CTE form).
- Clarity **3.5** — both queries readable; but presenting a broken query first, unflagged, misleads.
- Actionability **3.0** — a non-expert copies the FIRST query first and hits an analyzer error; they must scroll to the CTE to get a working query.
- **Q1 = (2.5+4.0+3.5+3.0)/4 = 3.25.** A real copy-paste failure on the lead query, offset by the correct CTE.

### SCOPE-CHECK — RESPONDER SYNTHESIS SLIP, NOT a resource defect → re-probe-don't-churn

Resources ALREADY teach, abundantly and correctly, that window functions cannot appear in WHERE:
- `r23` §3.1G LEADING CANONICAL + anti-pattern table L2007 (`WHERE RANK() OVER (...) = 2` → "Window function NOT allowed in WHERE … WHERE runs BEFORE windows are computed") + the migration-trap table L3259 (`WHERE ROW_NUMBER() OVER (...) = 1` → "NOT supported in any SQL dialect, including Trino" + the wrap-in-subquery rewrite) + L1779/L1806 ("window functions are illegal in WHERE in EVERY SQL dialect").
- `r27` L793 ("you cannot reference ANY SELECT output alias — nor a window-function result — in WHERE … filter them in an outer query / CTE too") + L1988 (`DELETE … WHERE ROW_NUMBER() OVER (...) > 1` defang).
- `r07` L3939 (NTILE: "window functions cannot go in WHERE … no QUALIFY") + L4722 (Top-N per group = window + outer WHERE).

The resources are correct and well-anchored, and the responder even PRODUCED the correct CTE form itself in the same answer — so the broken lead query is a **RESPONDER SYNTHESIS SLIP** (it generated the illegal form on its own despite having the right pattern at hand), NOT a content gap.

**iter905 = re-probe-don't-churn.** Re-probe "filter on a window-function result" / "find the row with the max windowed value" from a fresh phrasing next sweep to confirm the slip is a one-off. **Do NOT add any new "wrong" card and do NOT churn the §3.1G / L2007 / L3259 / r27-L793/L1988 / r07-L3939 window-in-WHERE guards — they are correct and comprehensive (a LIGHT FIX-A here would only duplicate existing pins).** No FIX-A this iter.

---

## Q2 — time-of-day order-volume bands — CORRECT (5.00)

`CASE WHEN EXTRACT(hour FROM created_at) >= 6 AND ... < 12 THEN 'morning' … ELSE 'night' END AS time_of_day, COUNT(*)`, `GROUP BY` the repeated CASE expression, `ORDER BY CASE time_of_day WHEN 'morning' THEN 1 …`.
- VERIFIED `datetime.html`: `EXTRACT(hour FROM ts)` / `extract(field FROM x) → bigint` valid, HOUR supported (0–23).
- GROUP BY repeats the CASE EXPRESSION (not an alias) → legal.
- ORDER BY references the output alias `time_of_day` inside a CASE → VERIFIED legal (output aliases usable in ORDER BY).
- CTE variant equivalent and correct.
**Q2 = 5.00.**

## Q3 — trailing-3-row rolling average per customer — CORRECT (5.00)

`AVG(value) OVER (PARTITION BY customer_id ORDER BY metric_date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS rolling_3row_avg`; tiebreaker `ORDER BY metric_date, metric_id` caveat noted.
- VERIFIED (Trino docs + Trino blog "new window features"): `ROWS BETWEEN 2 PRECEDING AND CURRENT ROW` is a 3-row physical frame (current + 2 preceding) → exactly the trailing-3 average; documented Trino example `avg(x) OVER (... ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)`.
- ROW-count frame (ROWS, not RANGE) correctly chosen for "3 most recent readings (row-count, not date)".
- Tiebreaker caveat (add `metric_id` to make ordering deterministic on duplicate dates) is the right nuance to raise.
- Minor completeness note (NOT a defect): the windowed form computes trailing-3 on EVERY row; the value for each customer's LATEST row is the "3-most-recent" average — reasonable interpretation, not a deduction.
**Q3 = 5.00.**

## Q4 — distinct product categories per customer — CORRECT (5.00)

`COUNT(DISTINCT category) AS num_categories … GROUP BY customer_id` (the one-number ask); plus `ARRAY_AGG(DISTINCT category ORDER BY category)` for the list.
- VERIFIED `aggregate.html`: `count(DISTINCT x)` valid; `array_agg()` ordering "can be specified by writing an ORDER BY clause within the aggregate function". Combining `DISTINCT` with `ORDER BY` on the SAME aggregated column (`array_agg(DISTINCT category ORDER BY category)`) is established Trino behavior — the only constraint is that ORDER BY sort keys must be in the argument list when DISTINCT is used, which holds here (sorting on `category`, the aggregated column).
- Correctly distinguishes the count (one number, the literal ask) from the optional list.
**Q4 = 5.00.**

---

## iter905 directive

**NO FIX-A. re-probe-don't-churn only.**
- Q1 window-fn-in-WHERE is a RESPONDER SYNTHESIS SLIP — resources are correct and comprehensive. Do NOT add a "wrong" card; do NOT churn the §3.1G / r23-L2007 / r23-L3259 / r27-L793 / r27-L1988 / r07-L3939 window-in-WHERE guards.
- iter905: re-probe "filter on / pick the row with a window-function result" from a fresh phrasing to confirm the slip is a one-off (it is well-guarded in resources, so expect a clean answer).
- Did NOT flag Q2/Q3/Q4 as defects — all verified correct vs source first (iter882 discipline).
- Federation (4.49944/310) is the only un-passed row — probe bulletproofed angles only.
- Do NOT touch any iter534–903 pin. PIN 467. NO federation edits. DO NOT bump `training/state.json` (already passed; overall 4.56 PASS holds).
