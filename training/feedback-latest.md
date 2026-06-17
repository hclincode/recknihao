# iter994 Judge Feedback — EXTENDED PHASE breadth sweep

**OVERALL 4.281 PASS** (Q1 4.8125 / Q2 3.5 / Q3 4.8125 / Q4 4.0 = 17.125/4 = 4.28125; margin +0.781; OVERALL AVERAGE governs, no per-Q veto — Q2 broken-secondary clause does NOT sink the iter).

All dialect / SQL-semantics / logic claims verified BOTH directions vs trino.io/docs/467 (functions/window.html: rank/dense_rank/row_number/ntile/first_value/last_value all real; ntile(n)="divides rows ... into n buckets ranging from 1 to at most n", remainder→earliest buckets [6 rows→1,1,2,2,3,4]; functions/aggregate.html: bool_and "Returns TRUE if every input value is TRUE, otherwise FALSE", ignores NULL + NULL on empty/all-NULL group per general aggregate rule) + WebSearch (window functions evaluated AFTER WHERE → illegal in WHERE; SELECT-list alias not resolvable in WHERE; subquery/CTE workaround) — NOT against resources/. Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark ingestion + dbt) — all 4 fit; NO federation drag-in.

---

## Q1 — RANK vs ROW_NUMBER for tied leaderboard, WHERE rank<=10 — **4.8125 CLEAN**

★ Tie semantics VERIFIED CORRECT: RANK() ties share rank then SKIP (1,2,2,4); DENSE_RANK() ties share NO skip (1,2,2,3); ROW_NUMBER() arbitrary among ties + always distinct. RANK() is the right pick for "tied for 3rd."
★ `RANK() OVER (ORDER BY SUM(order_amount) DESC)` window-OVER-aggregate inside a GROUP BY query = VALID 467 (aggregate computed first, window ranks the grouped output).
★ CTE + outer `WHERE spend_rank <= 10` CORRECT — window result filtered in an OUTER query (not in WHERE at the same level). NO QUALIFY misuse (correctly used a subquery/CTE; QUALIFY is not in 467).
★ "ties at rank 10 may yield >10 rows" caveat CORRECT and the honest behavior of RANK() for a leaderboard.
Acc 5.0 / Clar 4.75 / App 4.75 / Comp 4.75.

## Q2 — NTILE(4) quartiles — **3.5 — LEAD CORRECT + WON'T-RUN/POINTLESS appended WHERE (the ding)**

★ NTILE(4) lead is the CORRECT built-in for equal-count quartiles — VERIFIED valid 467 (ntile divides each partition into n buckets 1..n, remainder to earliest buckets; "10→3/3/2/2" exactly matches the doc's remainder-to-first-buckets rule). Quartile 1 = top 25% under `ORDER BY total_spend DESC` CORRECT. "No manual percentile cutoffs / no big CASE needed" CORRECT and exactly answers the ask. A user who runs ONLY the inner query + NTILE gets a fully correct quartile segmentation.
★ **THE DEFECT** — the example appends `WHERE spend_quartile IN (1,2,3,4)` where `spend_quartile` is the NTILE WINDOW-function alias defined in the SAME SELECT level. This is DOUBLE-illegal in Trino 467 and the query WILL NOT RUN:
  (a) **column-scope** — Trino does NOT resolve a SELECT-list output alias in WHERE; referencing `spend_quartile` in WHERE → "column 'spend_quartile' cannot be resolved" analysis error.
  (b) **window-in-WHERE** — even spelling out the NTILE expression, window functions are evaluated AFTER WHERE (after HAVING, before final SELECT/ORDER BY), so a window function may not appear in or behind WHERE at all → analysis error (VERIFIED via WebSearch: window funcs run after WHERE, must be pre-computed in a subquery/CTE to filter).
  It is ALSO **pointless** — NTILE(4) only ever emits 1–4, so `IN (1,2,3,4)` is a conceptual no-op even if it were legal.
Classify: NTILE(4) lead CORRECT; the appended WHERE = **broken + useless secondary clause** (column-scope / window-in-WHERE / broken-secondary slip family). RESPONDER slip (the runnable core is right), NOT a resource defect — re-probe-don't-churn. Scored down for shipping a non-running example query.
Acc 3.0 / Clar 4.0 / App 3.25 / Comp 3.75.

## Q3 — bool_and for "did all rows match" — **4.8125 CLEAN**

★ `bool_and(success = true)` VERIFIED — returns TRUE iff every input is TRUE, else FALSE; far cleaner than `SUM(CASE WHEN success THEN 1 ELSE 0 END)=COUNT(*)`. Exactly the requested aggregate.
★ NULL handling VERIFIED CORRECT — bool_and ignores NULLs and returns NULL for an empty group / all-NULL group (general aggregate rule; bool_and is NOT in the count/count_if/max_by/min_by/approx_distinct exception list). `COALESCE(bool_and(...), false)` guard for a guaranteed boolean CORRECT.
Minor (not a ding): `success = true` is redundant — `bool_and(success)` suffices when `success` is already boolean — harmless.
Acc 5.0 / Clar 4.75 / App 4.75 / Comp 4.75.

## Q4 — FIRST_VALUE "same session shows up twice with different first" — **4.0 — TIEBREAKER FIX CORRECT + MISLEADING FRAME HEADLINE + MISSING DEDUP (the dings)**

★ **CORE FIX CORRECT (load-bearing):** the real cause the responder identifies — `event_time` TIES → non-deterministic ORDER BY → FIRST_VALUE picks different rows across the partition's duplicate-timestamp evaluations — and the fix (add a deterministic tiebreaker `ORDER BY event_time, event_id`) is CORRECT and is the actual remedy for the symptom. Also correctly flags (1) genuinely-distinct sessions sharing a session_id as a data-quality cause.
★ **MISLEADING HEADLINE (ding):** "The problem is likely your default window frame" is WRONG for FIRST_VALUE. VERIFIED: the default value-function frame (RANGE UNBOUNDED PRECEDING → CURRENT ROW) DOES correctly return the partition's first row, because the first row is in EVERY row's frame. The default-frame gotcha is a **LAST_VALUE** issue (LAST_VALUE's frame ends at CURRENT ROW → returns the current row, not the partition last). The responder half-walks-it-back ("default frame usually works for FIRST_VALUE"), so the explicit `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` change is HARMLESS-but-UNNECESSARY for FIRST_VALUE — but leading with "likely your frame" mis-diagnoses. (FIRST_VALUE-vs-LAST_VALUE-frame tic.)
★ **MISSING DEDUP (completeness ding):** the user's literal symptom is "the same session shows up TWICE." `FIRST_VALUE(...) OVER (...)` still returns ONE ROW PER EVENT, not one per session — to truly get one row per session you need a collapse (SELECT DISTINCT session_id, first_page; or a `ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY event_time, event_id) = 1` subquery; or argmin via `min_by(page_url, event_time)` GROUP BY session_id). The responder did not add the collapse, so even with the tiebreaker the user can still see duplicate rows.
Classify: tiebreaker/determinism fix CORRECT (responder strength); misleading frame headline = RESPONDER mis-diagnosis (FIRST_VALUE-vs-LAST_VALUE-frame family); missing dedup = completeness gap. RESPONDER-side, re-probe-don't-churn.
Acc 4.0 / Clar 4.0 / App 4.0 / Comp 4.0.

---

## SCOPE

- **Q1 RANK/DENSE_RANK/ROW_NUMBER tie semantics CLEAN** — 1,2,2,4 vs 1,2,2,3 vs arbitrary VERIFIED; window-over-aggregate-in-GROUP-BY valid; CTE + outer `WHERE spend_rank<=10` correct (no QUALIFY); ties-at-10 may exceed 10 rows note correct.
- **Q2 NTILE(4) lead CORRECT** (equal-count quartiles, quartile 1=top 25% DESC, remainder-to-earliest-buckets verified) **+ the appended `WHERE spend_quartile IN (1,2,3,4)` = WON'T-RUN/POINTLESS defect** (column-scope: SELECT alias unresolvable in WHERE; window-in-WHERE: window funcs run after WHERE; AND conceptually a no-op since NTILE(4)∈{1,2,3,4}). Drop the WHERE → correct query.
- **Q3 bool_and CLEAN** — TRUE iff all TRUE; ignores NULL; NULL on empty/all-NULL; COALESCE(...,false) guard correct; `success=true` redundant-harmless.
- **Q4 tiebreaker-determinism fix CORRECT (load-bearing) + "frame issue" headline MISLEADING-for-FIRST_VALUE** (default value-frame returns first row fine; the gotcha is LAST_VALUE) **+ MISSING dedup-to-one-row-per-session** (FIRST_VALUE OVER still emits one row per event; need DISTINCT / ROW_NUMBER=1 / min_by).

## TICS

CLEAN except Q2 broken-secondary (column-scope/window-in-WHERE) and Q4 FIRST_VALUE-vs-LAST_VALUE-frame headline + missing-dedup: no QUALIFY (Q1 correctly used a CTE not QUALIFY) / false-mechanism-semi-join-mislabel / MAX-varchar / percent_rank-inversion / fabricated-fn (RANK/DENSE_RANK/ROW_NUMBER/NTILE/bool_and/FIRST_VALUE/LAST_VALUE ALL real & verified) / regex-backslash / GREATEST-LEAST-NULL / PARTITIONED-BY-foreign-DDL / mid-churn / missing-CTE-col / ts-minus-ts / ILIKE-conflation / INTERVAL-quarter-week / date_diff-boundary.

## RECOMMENDATION = DEFAULT NO-OP

Margin +0.781 PASS; all 4 LEADS are correct and verified both directions (RANK ties, NTILE(4) quartiles, bool_and, tiebreaker-determinism). The two dings are RESPONDER-side per-instance slips with NO findable resource/findability gap and NO 2-in-2 recurrence:
- Q2 broken-secondary `WHERE <window-alias>` is the recurring **broken-secondary / window-in-WHERE / column-scope** padding family (responder nails the lead then appends an illegal "for completeness" clause) — per-instance one-off, NOT a single-resource fix, do not churn. (Note Q1 demonstrated the CORRECT pattern in the SAME iter: compute the window in a CTE, filter in the outer WHERE.)
- Q4 "frame issue" headline + missing dedup is a RESPONDER mis-diagnosis + completeness gap, not a resource defect.

Re-probe next sweep:
- (a) another NTILE / equal-count bucketing Q — confirm NTILE(n) lead stays + watch the **window-alias-in-WHERE / broken-secondary** clause recur (2-in-2 on a worked window-bucket Q → per-instance responder padding, still NOT a resource fix; correct filter pattern is CTE/subquery then outer WHERE).
- (b) another FIRST_VALUE / LAST_VALUE / "first-or-last row per group" Q — confirm tiebreaker-determinism lead + watch the **FIRST_VALUE-vs-LAST_VALUE-frame** confusion recur AND whether the responder adds the dedup-to-one-row collapse (DISTINCT / ROW_NUMBER=1 / min_by/max_by). 2-in-2 on the frame mis-attribution → candidate LIGHT additive note ("default value-function frame returns the FIRST row fine; the frame gotcha is LAST_VALUE, whose frame ends at CURRENT ROW; FIRST_VALUE non-determinism is fixed by an ORDER BY tiebreaker, and one-row-per-group needs a dedup").
- (c) another RANK/DENSE_RANK vs ROW_NUMBER tie Q — confirm tie-semantics + outer-WHERE (no QUALIFY) lead stays.

Federation r22 §13.x hard-locked NOT probed (OVERRIDDEN). NO resource edits. DO NOT bump training/state.json (already 994; passed=true preserved; final_iterations_remaining 0).
