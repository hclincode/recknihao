# Judge Feedback — iter996 (EXTENDED PHASE breadth sweep)

**OVERALL 4.78125 STRONG PASS** (Q1 4.6875 / Q2 4.8125 / Q3 4.75 / Q4 4.875 = 19.125/4 = 4.78125; margin +1.28; OVERALL AVERAGE governs, no per-Q veto).

All 4 questions verified BOTH directions against trino.io/docs/467 (sql/select.html GROUP-BY-ordinal + no-alias + no-QUALIFY; functions/string.html split_part 1-based no-negative; functions/datetime.html EXTRACT(MONTH/YEAR FROM ts); functions/window.html window-funcs-run-after-HAVING-before-ORDER-BY → not in WHERE + row_number valid; functions/aggregate.html max_by(x,y) real) + pinned 467 source (reference_trino_cast_to_integer_rounds: CAST(decimal/double AS integer) ROUNDS half-up, truncate() drops decimals) — NOT against resources/. Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark ingestion + dbt) — all 4 fit; NO federation drag-in.

---

## Q1 — GROUP BY ordinal (GROUP BY 1, 2) valid vs repeat EXTRACT expressions — **4.6875 CLEAN**
- GROUP BY ordinal positions VERIFIED valid: select.html "a simple GROUP BY clause may contain any expression composed of input columns or it may be an ordinal number selecting an output column by position (starting at one)." `GROUP BY 1, 2` is correct.
- EXTRACT(MONTH FROM ts) / EXTRACT(YEAR FROM ts) VERIFIED valid (datetime.html `extract(field FROM x)→bigint`, YEAR/MONTH supported).
- SELECT-list ALIAS NOT referenceable in GROUP BY (`GROUP BY month, year` fails) — CORRECT. Trino resolves GROUP BY against INPUT columns/ordinals, not output aliases (#16533).
- MINOR terminology imprecision (not a defect): responder called the alias-in-GROUP-BY failure a "PARSE ERROR"; it is technically an analysis/resolution error ("column cannot be resolved"), not a strict parse error. Substance (aliases don't work in GROUP BY; use ordinal or repeat the full expression) is fully correct. Repeating the EXTRACT expressions also works (verbose) — correct.
- Acc 4.75 / Clar 4.75 / App 4.5 / Comp 4.75.

## Q2 — 'Direct'/'Organic'/'Other' Source column; COALESCE gave raw URL — **4.8125 CLEAN**
- CASE WHEN is the right tool, COALESCE is NOT — CORRECT. COALESCE(referrer_url,'Direct') only substitutes when NULL, otherwise returns the raw URL (exactly the user's symptom); it has no branching for the "contains google" / else cases.
- `CASE WHEN referrer_url IS NULL THEN 'Direct' WHEN referrer_url LIKE '%google%' THEN 'Organic' ELSE 'Other' END` — correct: top-to-bottom evaluation, first matching WHEN wins, ELSE fallback. IS NULL must come first (LIKE on NULL → UNKNOWN, won't match) — handled correctly by ordering.
- ELSE optional → defaults NULL when omitted — CORRECT (conditional.html).
- Acc 5.0 / Clar 4.75 / App 4.75 / Comp 4.75.

## Q3 — split_part for SKU numeric part + CAST leading zeros — **4.75 CLEAN**
- Trino HAS split_part — CORRECT (string.html `split_part(string, delimiter, index)→varchar`).
- 1-based positive index VERIFIED: "Field indexes start with 1." `split_part('SKU-00142','-',2)` = '00142' (index 1 = 'SKU' before dash, index 2 = '00142' after) — CORRECT. (Note: split_part has NO negative index in Trino — not raised here, not needed.)
- `CAST('00142' AS integer)` = 142 — CORRECT. String→integer parses the numeric value; leading zeros are display formatting only, stripped on conversion.
- ASIDE (correct, pinned): "CAST ROUNDS not truncates" for decimals — `CAST(47.89 AS integer)` = 48 (rounds half-up), use `truncate(47.89)` = 47 to drop decimals. VERIFIED against pinned 467 source (reference_trino_cast_to_integer_rounds). Responder correctly noted it doesn't affect the '00142' case (an exact-integer string). Good defensive accuracy, NOT the broken-secondary tic.
- Acc 5.0 / Clar 4.75 / App 4.5 / Comp 4.75.

## Q4 (KEY CHECK — iter994 window-in-WHERE re-probe) — top-3 per workspace — **4.875 CLEAN**
- Correctly diagnosed: `LIMIT 3` applies to the FINAL result set, giving top-3 OVERALL not per-group (matches user's symptom).
- Correct pattern VERIFIED: ROW_NUMBER() OVER (PARTITION BY workspace_id ORDER BY COUNT(*) DESC) computed in the INNER subquery SELECT over a GROUP BY workspace_id, page_path; OUTER query `WHERE rn <= 3` references rn as a PLAIN COLUMN (not a window function in WHERE).
  - (a) VALID Trino 467 — window fn lives in the subquery SELECT; outer WHERE filters a materialized column. CONFIRMED.
  - (b) ROW_NUMBER() OVER (... ORDER BY COUNT(*) DESC) window-OVER-aggregate inside a GROUP BY query is VALID (window funcs run after HAVING/aggregation — window.html "run after the HAVING clause but before ORDER BY"). CONFIRMED.
  - (c) "Trino has NO QUALIFY, window funcs can't go directly in WHERE, nest in subquery/CTE and filter the rank outside" — CONFIRMED (select.html has no QUALIFY; window funcs run before ORDER BY but after HAVING, so cannot appear in WHERE).
- ★ **iter994 window-fn/alias-in-WHERE slip did NOT recur.** Here the responder correctly nested the window in the subquery and filtered rn in the OUTER WHERE — the RIGHT pattern. iter994 NTILE-alias-in-WHERE confirmed a one-off responder padding slip, NOT a resource defect.
- Single-column top-1 alternative `max_by(page_path, views)` GROUP BY workspace_id over a per-page-count subquery — max_by VERIFIED real (aggregate.html `max_by(x,y)` "value of x associated with the maximum value of y"); valid alternative for top-1 only (responder scoped it correctly as single-column-top-1).
- Acc 5.0 / Clar 4.75 / App 4.875 / Comp 4.875.

---

## SCOPE NOTES
- **Q1**: GROUP BY ordinal (GROUP BY 1, 2) VALID + EXTRACT(MONTH/YEAR FROM ts) valid + SELECT-alias-NOT-in-GROUP-BY CORRECT; minor "PARSE ERROR" terminology (technically analysis/resolution error, substance correct).
- **Q2**: CASE-WHEN-not-COALESCE CORRECT (COALESCE only swaps NULL→single value, no branching; CASE first-match-wins + ELSE-fallback; IS NULL first).
- **Q3**: split_part 1-based positive index CORRECT (index 2='00142') + CAST('00142' AS int)=142 leading-zeros-stripped CORRECT + CAST-rounds-decimals aside (47.89→48, truncate→47) CORRECT/pinned.
- **Q4 (KEY)**: top-N-per-group = ROW_NUMBER() in INNER subquery SELECT over GROUP BY + OUTER WHERE rn<=3 (rn as plain column) CORRECT/valid Trino 467; window-over-aggregate-in-GROUP-BY valid; "no QUALIFY, nest+filter-outside" CORRECT; max_by single-column-top-1 alt CORRECT. **window-in-WHERE slip did NOT recur (iter994 one-off CONFIRMED).**

## TICS — ALL CLEAN
no QUALIFY (Q4 correctly says absent + uses subquery) / false-mechanism-semi-join-mislabel / MAX-varchar / percent_rank-inversion / fabricated-fn (split_part, ROW_NUMBER, max_by, EXTRACT, truncate ALL real & verified) / regex-backslash / GREATEST-LEAST-NULL / window-in-WHERE (Q4 ABSENT — correct subquery nesting) / GROUP-BY-alias (Q1 correctly rejects alias, uses ordinal) / date-minus-integer / broken-secondary-false-justification (Q3 CAST-rounds aside is accurate, not broken) / mid-churn / column-scope / DISTINCT-vs-GROUP-BY-folklore / ILIKE-conflation / INTERVAL-quarter-week.

## RECOMMENDATION = DEFAULT NO-OP
Margin +1.28; all 4 leads correct & verified both directions; zero tics; no findable resource/findability gap; no 2-in-2 recurrence; Q4 KEY CHECK clean (window-in-WHERE one-off confirmed, NOT a resource defect). Re-probe next sweep: (a) another top-N-per-group / window-rank Q — confirm ROW_NUMBER-in-subquery + OUTER-WHERE-rank lead stays + watch window-in-WHERE recurrence (still per-instance responder padding if it reappears, not a resource fix); (b) another conditional/fallback Q — confirm CASE-vs-COALESCE distinction stays; (c) another string-parse/CAST Q — confirm split_part-1-based + CAST-rounds-vs-truncate stays. Federation r22 §13.x hard-locked NOT probed (OVERRIDDEN). NO resource edits. DO NOT bump training/state.json (already 996; passed=true preserved; final_iterations_remaining 0).
