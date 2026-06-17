# iter993 Judge Feedback — EXTENDED PHASE breadth sweep

**OVERALL 4.40625 PASS** (Q1 3.875 / Q2 4.8125 / Q3 4.75 / Q4 4.875 = 17.3125/4 = 4.40625; margin +0.906; OVERALL AVERAGE governs, no per-Q veto). All 4 dialect/SQL-semantics claims verified BOTH directions vs trino.io/docs/467 (sql/select.html UNNEST-of-map; functions/window.html SUM OVER; functions/datetime.html date_add; language/reserved.html KEY/VALUE) + pinned 467 div-by-zero source — NOT against resources/. Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark ingestion + dbt) — all 4 fit; NO federation drag-in.

---

## Q1 — Month-over-month (previous month next to current to subtract) — 3.875

**SQL CORRECT, PROSE MISSTATEMENT (the ding).**

- ★ **Self-join logic VERIFIED CORRECT for MoM:** `LEFT JOIN monthly_revenue prev ON prev.month = date_add('month', -1, cur.month)` correctly pairs each current month with the PREVIOUS month → `cur.revenue_total - prev.revenue_total` is genuine month-over-month. `date_add('month', -1, date)` is valid Trino 467 and returns the prior month (datetime.html: signature `date_add(unit, value, timestamp)`, negative value subtracts). VERIFIED.
- `ROUND((cur - prev) * 100.0 / NULLIF(prev.revenue_total, 0), 2)` — `100.0 *` forces decimal promotion (correct), `NULLIF(prev,0)` guards pct div-by-zero (returns NULL not throw, correct). LEFT JOIN → NULL prev for the first month (correct).
- ★ **PROSE DISCREPANCY (the ding):** the responder's TEXT says the query "matches each month's total to the same month from the PRIOR YEAR." The SQL does prior MONTH (`date_add('month', -1, ...)`), which is what the question asked for. The SQL — what the user actually runs — is CORRECT for MoM; the "prior year" description is a misstatement that would confuse a beginner reading the explanation. Classify as a **minor clarity/accuracy slip (prose-vs-SQL discrepancy family), NOT a logic defect.** RESPONDER slip, not a resource defect.
- TRIVIAL inconsistency: prose says "multiply numerator by 1.0 to force float" while the SQL uses `100.0` — cosmetic, no impact (both promote to decimal).
- COMPLETENESS improvement (not required): the question literally describes "put previous month's number right next to current month's in the same row" — that is the textbook **`LAG(revenue_total) OVER (ORDER BY month)`** idiom, which is simpler and exactly fits the phrasing. The self-join works and is correct but is more verbose; LAG would have been the cleaner lead. Note as completeness, not a defect.

Acc 3.75 / Clar 3.75 / App 4.0 / Comp 4.0.

---

## Q2 — Running cumulative total of revenue by day — 4.8125 CLEAN

- ★ **`SUM(revenue) OVER (ORDER BY day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` VERIFIED CORRECT** for a running total in Trino 467 (window.html: "All Aggregate functions can be used as window functions by adding the OVER clause"; "computed for each row over the rows within the current row's window frame"). Explicit ROWS frame from UNBOUNDED PRECEDING to CURRENT ROW = canonical cumulative-sum form.
- Correctly explained SUM OVER does NOT collapse rows (vs SUM GROUP BY which gives only per-day totals — the user's exact symptom).
- WHERE-before-window note (pruning OK) accurate; `PARTITION BY product_id` variant for multiple independent series correct.

Acc 5.0 / Clar 4.75 / App 4.75 / Comp 4.75.

---

## Q3 — Division-by-zero guard on commission/unit_price (unit_price literally 0) — 4.75 CLEAN

- ★ **VERIFIED:** INTEGER/DECIMAL `/` by zero THROWS DIVISION_BY_ZERO in Trino 467 (matches the user's symptom; pinned 467-source reference). `commission / NULLIF(unit_price, 0)` → NULL denominator → NULL result, no throw — the cleanest guard, exactly the ask ("without a big CASE"). CORRECT.
- The CASE alternative `CASE WHEN unit_price=0 THEN 0 ELSE commission/unit_price END` is also correct (the responder correctly framed NULLIF as the idiomatic shorter path).
- No 100.0/decimal-promotion concern here — `commission/unit_price` is a plain ratio, not a percentage. NULLIF cross-reference to the weighted-avg `NULLIF(SUM(weight),0)` idiom is apt.

Acc 5.0 / Clar 4.75 / App 4.5 / Comp 4.75.

---

## Q4 — Count distinct values per map key (properties map(varchar,varchar)) — 4.875 CLEAN

- ★ **VERIFIED:** `CROSS JOIN UNNEST(properties) AS t(key, value)` is valid Trino 467. select.html: "Maps are expanded into two columns (key, value)" with doc example `... AS t(language, first_appeared_year)` confirming custom aliasing of the two map columns. So UNNEST(map) → one row per key-value pair, and `AS t(key, value)` correctly names them.
- ★ **`key` and `value` are NOT reserved words** in Trino 467 (language/reserved.html — neither KEY nor VALUE appears) → usable as bare column aliases without quoting. No parse-break.
- `WHERE key='plan' GROUP BY value COUNT(DISTINCT user_id)` correctly answers "how many users have each distinct value for a given key." CORRECT.
- ★ **`LEFT JOIN UNNEST(...) ON TRUE` to preserve parents with NULL/empty maps VERIFIED valid** (select.html: "LEFT JOIN is preferable in order to avoid losing the row ... Note that in case of using LEFT JOIN the only condition supported ... is ON TRUE"). Correct caveat.
- SIMPLER single-key alternatives existed and were NOT required: `element_at(properties,'plan')` + GROUP BY, or `histogram(element_at(properties,'plan'))`. Note as alternatives only — the UNNEST path is fully correct and generalizes.

Acc 5.0 / Clar 4.75 / App 4.875 / Comp 4.875.

---

## TICS scan

ALL CLEAN except the Q1 prose/SQL discrepancy:
- no QUALIFY; no false-mechanism semi-join mislabel; no MAX(varchar); no percent_rank inversion; no fabricated functions (date_add, UNNEST-of-map, NULLIF, SUM OVER, element_at, histogram ALL real & verified); no regex-backslash; no GREATEST/LEAST-NULL error; no PARTITIONED-BY foreign DDL; no broken-secondary/false-justification; no mid-churn; no missing-CTE-col; no column-scope error; no ILIKE-conflation.
- **Q1 "prior YEAR" prose** = the sole blemish — prose-vs-SQL discrepancy (SQL does prior month and is CORRECT for MoM); RESPONDER slip, not a resource defect.

## SCOPE / disposition

- **Q1**: self-join MoM SQL CORRECT (date_add('month',-1,...) = prior month, 100.0 promotion, NULLIF pct-guard, LEFT JOIN→NULL first month) + **"prior YEAR" prose misstatement** (SQL does prior MONTH — minor clarity/accuracy slip, not logic) + **LAG(revenue_total) OVER (ORDER BY month) is the simpler canonical idiom** the question literally describes (completeness improvement).
- **Q2**: SUM(...) OVER (ORDER BY day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) running total VERIFIED clean; PARTITION BY variant correct.
- **Q3**: NULLIF(unit_price,0) div-by-zero guard VERIFIED clean (INTEGER/DECIMAL `/0` throws; NULLIF→NULL); CASE alt correct.
- **Q4**: CROSS JOIN UNNEST(map) AS t(key,value) → GROUP BY value COUNT(DISTINCT user_id) VERIFIED clean; key/value not reserved; LEFT JOIN UNNEST ON TRUE for NULL/empty maps valid.

## RECOMMENDATION = DEFAULT NO-OP

Margin +0.906 PASS; all 4 leads correct and verified both directions; the single ding (Q1 "prior year" prose) is a RESPONDER prose-vs-SQL slip with the runnable SQL correct — no findable resource/findability gap, no 2-in-2 recurrence. Re-probe next sweep:
- (a) another MoM / period-over-period Q — confirm self-join OR LAG lead + watch the "prior year"-vs-"prior month" prose accuracy (2-in-2 prose-vs-SQL → per-instance responder slip, not a resource fix); ideally see if LAG surfaces as lead.
- (b) another map-key value-frequency Q — confirm UNNEST(map) key/value or element_at lead stays.
- (c) another running-total/window-frame Q — confirm SUM OVER ROWS frame stays.

Federation r22 §13.x hard-locked — NOT probed (OVERRIDDEN). NO resource edits. DO NOT bump training/state.json (already 993; passed=true preserved; final_iterations_remaining 0).
