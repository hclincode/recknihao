# iter987 Judge Feedback (EXTENDED PHASE breadth sweep)

**OVERALL 4.5781 STRONG PASS** (Q1 4.6875 / Q2 4.75 / Q3 4.0 / Q4 4.625 = 18.3125/4 = 4.5781; margin +1.078; OVERALL AVERAGE governs, no per-Q veto).

All 4 Qs verified BOTH directions vs trino.io/docs/467 (NOT resources/):
- comparison.html — LIKE "case sensitive", NO ILIKE operator/keyword listed; case-insensitive = UPPER()/LOWER() wrap.
- regexp.html — `(?i)` inline flag IS supported ("Case-insensitive matching ... enabled via the `(?i)` flag"); Java pattern syntax.
- TopN: `TopNPartial[n by (col ASC/DESC NULLS LAST)]` is a real EXPLAIN plan node (WebSearch trinodb/trino #6634, #5372); `ORDER BY ... LIMIT N` uses bounded TopN, NOT a full Sort.
- select.html — WHERE filters rows BEFORE grouping; HAVING "filters groups after groups and aggregates are computed"; aggregate in WHERE invalid.
- math.html — `/` "integer division performs truncation" (confirms decimal-promotion note for Q4). DIVISION_BY_ZERO throw for INTEGER/DECIMAL + DOUBLE/REAL→Infinity/NaN per IEEE-754 confirmed via verified 467-source memory (reference_trino_division_by_zero.md; r27 §4.4H LOCKED).

Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark ingestion + dbt) — all answers fit; NO federation drag-in this iter.

---

## ★ Q2 — THE KEY CHECK (2nd-consecutive ILIKE-conflation re-probe): CLEAN — iter986 slip CONFIRMED ONE-OFF
**Case-insensitive plan_name match. Score 4.75.**
- "Trino 467 does NOT have ILIKE (PostgreSQL only)" — VERIFIED CORRECT (comparison.html lists no ILIKE; #2491 DECLINED).
- Option 1 `WHERE LOWER(plan_name) = 'pro'` — VERIFIED valid + canonical idiom.
- Option 2 `regexp_like(plan_name, '(?i)^pro$')` — VERIFIED valid 467 (regexp.html confirms `(?i)` inline flag; `^pro$` anchors exact 'pro' case-insensitively = correct for equality-style match).
- Option 3 normalize at ingest + "function-wrapped column skips partition pushdown" — sound.
- ★ **ILIKE-conflation DID NOT RECUR**: responder did NOT claim ILIKE works via any session property (no `enable_string_pushdown_with_collate`), did NOT drag in federation/Postgres-connector pushdown, did NOT cite r22. The iter986 Option-B false-mechanism slip is **CONFIRMED A ONE-OFF** over this clean re-probe. No FIX-A, no resource edit, no LIGHT-defang warranted.
- Acc 4.75 / Clar 4.75 / App 4.75 / Comp 4.75.

## ★ Q3 — TopN-not-full-sort CORRECT, but scan-reduction claim is an OVERSTATEMENT
**Top 10 pages by total views, last 30 days. Score 4.0.**
- "Safe; Trino does NOT force a full sort for ORDER BY ... LIMIT N" — VERIFIED CORRECT (TopNPartial bounded-heap node, not a full Sort).
- Query correct: `... GROUP BY page_url ORDER BY total_views DESC LIMIT 10` with `WHERE occurred_at >= current_timestamp - INTERVAL '30' DAY` (valid 467; DAY is a legal interval qualifier).
- "Verify with EXPLAIN (TopN vs Sort node)" — good, actionable.
- ★ **OVERSTATEMENT / accuracy imprecision (the ding)**: responder says it "reads and aggregates only enough rows to maintain a running set of the top 10" and "not reading billions of rows before filtering to 10." For a **GROUP BY + ORDER BY agg DESC LIMIT 10**, Trino MUST aggregate ALL rows in the 30-day window — it cannot know the top-10 page_urls by count without counting every page's rows. TopN only avoids SORTING the grouped results; it does NOT avoid SCANNING/aggregating the windowed rows. The 30-day WHERE limits the scan via partition pruning (IF partitioned by date), but within the window all rows are read. The running-top-10 heap applies to the AGGREGATED output rows, not the raw input. **Classify: minor accuracy imprecision, NOT a hard defect** (the TopN-not-full-sort core is correct; only the scan-reduction framing is loose). RESPONDER imprecision, NOT a resource defect.
- Acc 3.75 / Clar 4.0 / App 4.25 / Comp 4.0.

## Q1 — WHERE vs HAVING: CLEAN (iter986 boundary slip did NOT recur)
**total invoice count 5 or fewer; `WHERE COUNT(*) <= 5` errors. Score 4.6875.**
- "Aggregates can't go in WHERE (runs before aggregation); move to HAVING" — VERIFIED CORRECT.
- `... GROUP BY workspace_name HAVING COUNT(*) <= 5` — VERIFIED CORRECT.
- ★ **Boundary CORRECT**: "5 or fewer" = `<= 5` (keeps exactly 5). The iter986 Q1 `>5`-should-be-`>=5` off-by-one slip **DID NOT RECUR** — boundary tracked correctly this iter.
- HAVING correctly REPEATS aggregate `COUNT(*)`, NOT the alias `invoice_count` (correct; aliases not referenceable in HAVING).
- Non-agg→WHERE / agg→HAVING perf note sound.
- Acc 4.75 / Clar 4.75 / App 4.625 / Comp 4.625.

## Q4 — division-by-zero guard: CORRECT, minor decimal-promotion completeness note
**refund % of revenue; zero-revenue months blow up. Score 4.625.**
- "Trino throws DIVISION_BY_ZERO for INTEGER/DECIMAL div by zero" — VERIFIED CORRECT (467-source; r27 §4.4H LOCKED).
- Fix `refund_total / NULLIF(revenue_total, 0) * 100` → NULL when revenue=0 — VERIFIED CORRECT (the actual ask).
- "DOUBLE/REAL div-by-zero returns Infinity/NaN per IEEE-754 (doesn't throw)" — VERIFIED CORRECT.
- `COALESCE(refund_total / NULLIF(revenue_total,0) * 100, 0)` to show 0 — correct.
- ★ **MINOR completeness note (NOT a defect)**: math.html confirms `/` does INTEGER truncation. If `refund_total`/`revenue_total` are INTEGER, the division truncates toward zero BEFORE `* 100` (e.g. 5/100 = 0), so the percentage needs `100.0 *` leading (decimal promotion) or a CAST. Responder did NOT surface decimal promotion. For DECIMAL/DOUBLE money columns (typical) it's fine, and the div-by-zero guard — the actual question — is fully correct. Minor comp ding only.
- Acc 4.75 / Clar 4.5 / App 4.625 / Comp 4.625.

---

## SCOPE / classification
- **Q2 ILIKE-conflation DID NOT RECUR** — routed to `LOWER(plan_name)='pro'` + `regexp_like(plan_name,'(?i)^pro$')`; no session-property false-mechanism, no federation drag-in, no r22 citation. iter986 Option-B slip **CONFIRMED ONE-OFF**. No 2-in-2, NO LIGHT-defang warranted.
- **Q1 HAVING `<= 5` correct boundary** — iter986 `>5`-vs-`>=5` off-by-one did NOT recur.
- **Q3 TopN-not-full-sort CORRECT** but "reads only enough rows / doesn't read billions" is an OVERSTATEMENT for the GROUP BY case (must aggregate all windowed rows; TopN only skips the final sort) — RESPONDER imprecision, minor accuracy ding, NOT a resource defect.
- **Q4 NULLIF guard correct**; minor decimal-promotion (`100.0 *`) completeness note unaddressed.
- TICS otherwise CLEAN: no QUALIFY / false-mechanism-semi-join-mislabel / MAX-varchar / percent_rank-inversion / fabricated-fn-or-rule-or-session-property / PARTITIONED-BY-foreign-DDL / aggregate-in-GROUP-BY / broken-secondary-false-justification / mid-churn / missing-CTE-col / JOIN-fan-out / ts-minus-ts / column-scope. ILIKE-conflation ABSENT (Q2 clean). HAVING-boundary CORRECT (Q1).

## RECOMMENDATION = DEFAULT NO-OP
Margin +1.078; all four leads correct. The only two dings are RESPONDER-side and minor (Q3 scan-reduction overstatement, Q4 unaddressed decimal promotion) — no findable resource/findability gap. Q2 ILIKE-conflation confirmed one-off; Q1 boundary correct.

Re-probe next sweep: (a) another `ORDER BY ... LIMIT` / top-N-on-aggregate Q — watch whether responder still overstates "reads only enough rows" for the GROUP BY case (if it recurs 2-in-2 on a worked aggregate top-N, candidate for a LIGHT additive note "TopN skips the final SORT, not the aggregation/scan of the windowed rows; only partition pruning reduces the scan"); (b) another percentage/ratio Q — watch decimal-promotion (`100.0 *` / CAST) on INTEGER columns. Federation r22 §13.x hard-locked NOT probed (OVERRIDDEN). NO resource edits. DO NOT bump training/state.json (already 987; passed=true preserved; final_iterations_remaining 0).
