# iter981 Judge Feedback — EXTENDED PHASE breadth sweep

**OVERALL 4.6875 STRONG PASS** (Q1 4.75 / Q2 4.75 / Q3 4.5625 / Q4 4.6875 = 18.75/4 = 4.6875; margin +1.19; OVERALL AVERAGE governs, no per-Q veto).

All 4 questions verified BOTH directions against trino.io/docs/467 (NOT resources/):
- functions/datetime.html — `date(x)` IS a documented 467 function, exact doc text "This is an alias for CAST(x AS date)"; INTERVAL '90' DAY valid; `current_timestamp - INTERVAL '90' DAY` valid (timestamp ± interval shown in operators table).
- functions/aggregate.html — FILTER (WHERE ...) clause "supported for all aggregate functions", example `count(*) FILTER (where ...)`.
- sql/select.html — HAVING must REPEAT the full aggregate expression; SELECT output aliases are NOT referenceable in HAVING (doc example repeats `sum(acctbal)` in HAVING, not the alias `totalbal`).
- WebSearch 2026-06-17 — LEFT JOIN anti-join recency-filter semantics: a right-table date predicate placed in a post-join WHERE drops NULL-padded unmatched rows and collapses the LEFT JOIN into an INNER JOIN; the filter must live in the ON clause (or in a NOT EXISTS subquery). Standard across all SQL engines incl. Trino.

Q2 and Q4 logic TRACED on concrete examples. Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark ingestion + dbt) — all answers fit.

---

## Q1 — CTR > 5% per campaign, conditional aggregation + subqueries — 4.75 CLEAN

`COUNT(*) FILTER (WHERE event_type='click')` / `FILTER (WHERE event_type='send')` + `ROUND(100.0*clicks/NULLIF(sends,0),2)` + `HAVING COUNT(*) FILTER (WHERE event_type='send')>0 AND 100.0*COUNT(*) FILTER(WHERE ...click)/NULLIF(COUNT(*) FILTER(WHERE ...send),0) > 5.0 ORDER BY ctr_pct DESC`.

- FILTER clause VERIFIED valid 467 (supported for all aggregates).
- NULLIF div-guard correct — INTEGER `/` by zero THROWS DIVISION_BY_ZERO in 467; NULLIF(sends,0) makes a 0-send campaign yield NULL not an error.
- 100.0* forces decimal arithmetic (else integer division floors) — correct.
- **HAVING-alias verdict: CORRECT.** The HAVING repeats the full FILTER aggregate expressions; it does NOT reference the SELECT alias `ctr_pct`. VERIFIED 467 does NOT allow output aliases in HAVING (doc example repeats the aggregate), so repeating the FILTER expressions is the right (and only valid) form. No defect.
- CASE WHEN alternative for the conditional aggregation is also valid.

Acc 4.75 / Clar 4.75 / App 4.75 / Comp 4.75.

## Q2 — highest single-day revenue per store, past 90d — 4.75 CLEAN — THE DATE() KEY CHECK

`WITH daily_revenue AS (SELECT store_id, DATE(timestamp) AS order_date, SUM(order_total) AS daily_total FROM orders WHERE timestamp >= current_timestamp - INTERVAL '90' DAY GROUP BY store_id, DATE(timestamp)) SELECT store_id, MAX(daily_total) FROM daily_revenue GROUP BY store_id` + which-day JOIN variant + ROW_NUMBER tie note.

- **DATE() VERDICT: VALID 467 FUNCTION — NOT a MySQL/Spark-ism.** VERIFIED trino.io/docs/467 functions/datetime.html: `date(x)` is documented, exact text "This is an alias for CAST(x AS date)". So `DATE(timestamp)` cleanly extracts the calendar date. Q2 is FULLY clean — no dialect ding. (CAST(timestamp AS DATE) / date_trunc('day',ts) are equivalent alternatives, but DATE() is itself a documented built-in, so the responder's choice is correct, not an imported foreign-prior.)
- Two-level aggregation LOGIC correct: per-store-per-day SUM in CTE -> MAX(daily_total) per store. TRACE store S over 3 days {120, 340, 90}: daily_revenue rows (S,d1,120)(S,d2,340)(S,d3,90) -> MAX=340 the highest single-day. CORRECT.
- which-day variant (JOIN daily_revenue to max-per-store on store_id AND daily_total; ROW_NUMBER tiebreaker for two days tying the max) correct.
- `current_timestamp - INTERVAL '90' DAY` VERIFIED valid (DAY is a supported interval qualifier; timestamp ± interval valid).
- CTE projects store_id/order_date/daily_total — all three referenced downstream, no missing-CTE-column defect.

Acc 4.75 / Clar 4.75 / App 4.75 / Comp 4.75.

## Q3 — current total storage per workspace, signed byte_size — 4.5625 CLEAN

`SELECT workspace_id, SUM(byte_size) AS current_total_bytes_used FROM storage_events GROUP BY workspace_id ORDER BY ... DESC`.

- Signed SUM nets correctly: uploads contribute +byte_size, deletions -byte_size; SUM over signed values = net current storage. VERIFIED arithmetic — correct.
- "current total = cumulative sum of ALL events, no date filter needed" is the RIGHT interpretation. A date filter would give a per-window delta, not the standing total — the responder correctly avoided one.
- No division / no dedup needed — confirmed; each event is a distinct signed delta.
- Minor comp note (not a defect): a brief caveat that this assumes no double-counted/duplicate events and that a negative running balance would signal a data-quality issue could add value, but the explicit ask (is a simple GROUP BY SUM enough?) was answered correctly and completely.

Acc 4.625 / Clar 4.625 / App 4.5 / Comp 4.5.

## Q4 — products with ZERO sales this month, anti-join + recency — 4.6875 CLEAN — THE DATE-FILTER-IN-ON-CLAUSE CHECK

`SELECT p.product_id, p.product_name FROM products p LEFT JOIN order_line_items oli ON p.product_id=oli.product_id AND DATE_TRUNC('month', oli.order_timestamp)=DATE_TRUNC('month', current_timestamp) WHERE oli.product_id IS NULL ORDER BY p.product_id` + NOT EXISTS alternative with the date filter INSIDE the subquery.

- **ANTI-JOIN-DATE-FILTER-IN-ON-CLAUSE: CONFIRMED CORRECT.** The responder put the month predicate in the ON clause and EXPLICITLY explained that a post-join WHERE on the right table's column (oli.order_timestamp) would turn the LEFT JOIN into an INNER JOIN and break no-match detection — and showed the WRONG form. VERIFIED correct (standard SQL outer-join semantics, holds in Trino 467).
- TRACE (products P1/P2/P3; oli: P1 sold this month, P2 sold last month only, P3 never): ON-clause month filter -> P1 matches a this-month row (oli.product_id NOT NULL -> dropped by WHERE IS NULL, correct, P1 HAS this-month sales); P2's only rows are last-month so ON month-condition fails -> NULL-padded -> IS NULL -> KEPT (correct, zero sales THIS month); P3 no rows -> NULL-padded -> KEPT. Result {P2,P3} = exactly products with zero sales this month. CORRECT.
- Counter-trace of the WRONG form: month filter in WHERE -> P2's NULL-padded row has order_timestamp=NULL -> DATE_TRUNC('month',NULL)=... -> NULL -> UNKNOWN -> row dropped -> P2 wrongly excluded. Responder's explanation matches.
- NOT EXISTS alternative with the date filter INSIDE the correlated subquery is also correct (the recency predicate scopes the existence check, not a post-join filter).
- LEFT JOIN/IS NULL correctly described as an anti-join — NOT mislabeled a SemiJoin (the iter960/963/978 false-mechanism family did NOT recur here).

Acc 4.75 / Clar 4.625 / App 4.75 / Comp 4.625.

---

## Scope notes

- **Q2 DATE() verdict (explicit per directive): `date(x)` IS a documented Trino 467 function — alias for CAST(x AS date) — NOT a MySQL/Spark-ism.** Q2 is fully clean with no dialect ding.
- **Q4 anti-join-date-filter-in-ON-clause (explicit per directive): CORRECT.** Date predicate in ON clause + WHERE right.key IS NULL preserves the anti-join; the responder correctly explained the post-join-WHERE-collapses-to-INNER-JOIN trap and gave the NOT EXISTS alternative with the filter inside the subquery.
- Q1 HAVING repeats the full FILTER aggregate expressions (does NOT use the ctr_pct alias) — correct, since 467 disallows output aliases in HAVING.

## Tics — ALL CLEAN

No QUALIFY-misuse; no false-mechanism semi-join mislabel (Q4 LEFT JOIN/IS NULL correctly named anti-join); no MAX(varchar)-as-latest (Q2 MAX over numeric daily_total + ROW_NUMBER tiebreaker); no percent_rank inversion; no fabricated function/rule (Q2 DATE() VERIFIED REAL — did NOT assume fabrication); no PARTITIONED-BY foreign DDL; no broken secondary / false justification; no mid-churn; no missing-CTE-column (Q2 CTE projects + references all three cols); no JOIN fan-out (Q4 anti-join, no fan-out; Q2 pre-aggregates per store-day); no ts-minus-ts (Q2 uses timestamp - INTERVAL literal, which IS valid arithmetic).

## Recommendation = DEFAULT NO-OP

Margin +1.19, all 4 answers clean, zero responder slips this sweep. No resource defect, no findability gap. No FIX-A. ZERO resource edits.

Re-probe next sweep:
- (a) another date-extraction Q to confirm DATE()/CAST-AS-DATE/date_trunc('day',...) all stay correctly treated (DATE() is a real 467 fn — should never be flagged as foreign).
- (b) another anti-join-with-recency Q (date filter in ON clause OR NOT EXISTS subquery; confirm the post-join-WHERE-breaks-it explanation + correct anti-join naming both persist; 2 consecutive clean retires the iter978 SemiJoin-mislabel concern further).

Federation r22 §13.x hard-locked — NOT probed (OVERRIDDEN).
DO NOT bump training/state.json (already 981; passed=true preserved; final_iterations_remaining 0).
