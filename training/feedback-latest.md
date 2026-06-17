# iter1001 Judge Feedback

**Iteration**: 1001 (EXTENDED PHASE breadth sweep; 0 resource edits expected)
**Verification**: All claims verified against trino.io/docs/467 + RAW git-tag 467 source (raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/sql/select.md), NOT resources/. PINNED Trino 467.
**Prod stack** (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark ingestion + dbt) — all 4 Qs fit; no federation drag-in; no auth angle.

## Per-question scores

### Q1 — Group login events by hour-of-day; EXTRACT(hour FROM created_at) usable in GROUP BY/WHERE like Postgres? — **4.8125 CLEAN**
- VERIFIED at functions/datetime.html: `extract(field FROM x) → bigint`. EXTRACT(HOUR FROM timestamp) returns a **bigint** (integer 0–23), directly usable in GROUP BY and WHERE — matches Postgres on this point. CORRECT.
- Supported fields VERIFIED: HOUR/MINUTE/SECOND/DAY/DAY_OF_WEEK(DOW)/DAY_OF_MONTH/DAY_OF_YEAR/MONTH/QUARTER/YEAR/WEEK/etc. Responder's field list correct.
- `GROUP BY EXTRACT(hour FROM created_at)` valid (basic GROUP BY accepts expressions). CORRECT.
- Acc 5.0 / Clar 4.75 / App 4.75 / Comp 4.75.

### Q2 — amount integer cents (10099); amount/100 = 100 not 100.99; what's going on + how to get decimal? — **4.6875 CLEAN (minor terminology ding)**
- Integer/integer division truncates toward zero VERIFIED: 10099/100 = 100. Correct diagnosis of the classic integer-division trap.
- Fix `amount / 100.0` VERIFIED: `100.0` (non-scientific decimal notation) is a **DECIMAL literal** in Trino 467 (language/types.html: scientific notation like `1.03e1` casts to DOUBLE; plain `100.0` is DECIMAL), so the division promotes to DECIMAL → 100.99. CORRECT.
- `CAST(amount AS DECIMAL) / 100` also works. CORRECT.
- ★ MINOR TERMINOLOGY IMPRECISION (not a defect): responder wrote "100.0 promotes the calculation to decimal/floating-point arithmetic." `100.0` is specifically a DECIMAL literal → DECIMAL division, NOT floating-point (a DOUBLE result would need `100e0` / CAST AS DOUBLE). Substance (promotes to decimal, yields 100.99) is correct; light deduct on accuracy/clarity only.
- Acc 4.5 / Clar 4.625 / App 4.75 / Comp 4.875.

### Q3 — DISTINCT plan,region vs GROUP BY plan,region; meaningful difference? which to use? — **4.8125 CLEAN — iter989 FOLKLORE DID NOT RECUR**
- `SELECT DISTINCT plan, region` and `SELECT plan, region ... GROUP BY plan, region` are SEMANTICALLY EQUIVALENT (same result rows) and Trino plans them essentially identically — no perf winner. CONFIRMED.
- ★ Responder said "both perform well on Trino; pick whichever reads better" and did NOT assert "GROUP BY faster than DISTINCT" — CORRECT. The iter989 DISTINCT-vs-GROUP-BY perf-folklore **DID NOT RECUR (one-off confirmed; folklore clean).**
- DISTINCT = pure dedup (more readable); GROUP BY = needed when you add aggregates (COUNT(*) etc.). Correct, useful framing.
- Acc 5.0 / Clar 4.75 / App 4.75 / Comp 4.75.

### Q4 — Daily summary: total + per-region subtotals + grand total in ONE query (currently 3 UNIONs); single-query GROUP BY variant? — **4.8125 CLEAN — KEY CHECK: ROLLUP-NO-EXPRESSIONS CAVEAT IS *CORRECT*, NOT A FABRICATION**
- `GROUP BY ROLLUP(region)` emits per-region rows + a grand-total row in one query. VERIFIED CORRECT.
- `GROUPING(region)` = 0 for detail rows / 1 for the grand-total (aggregated) row; single-column bitmask; label via CASE. VERIFIED CORRECT (functions/aggregate.html GROUPING bitmask).
- ★★ **THE SUSPECT CLAIM — VERIFIED, RESPONDER IS RIGHT.** The run-prompt's "strong prior" (that ROLLUP/CUBE/GROUPING SETS accept arbitrary expressions, so the responder fabricated an over-restrictive limitation) is **WRONG**. Verified at trino.io/docs/467 sql/select.html AND raw git-tag 467 source (sql/select.md), verbatim: *"Complex grouping operations do not support grouping on expressions composed of input columns. Only column names are allowed."* Grammar shows `GROUPING SETS ( ( column [, ...] ) [, ...] ) | CUBE ( column [, ...] ) | ROLLUP ( column [, ...] )` — **column**, not expression. Basic GROUP BY accepts expressions; ROLLUP/CUBE/GROUPING SETS do NOT.
- Therefore the responder's caveat "ROLLUP works with COLUMN NAMES ONLY, not expressions — if you need a date part, pre-compute it in a CTE first" is **FULLY CORRECT and the documented best practice**, NOT a fabricated over-restrictive limitation. The `WITH ... GROUP BY ROLLUP(yr, region)` CTE-precompute workaround is exactly the right pattern.
- ★ IMPORTED-PRIOR TRAP AVOIDED (judge side): same family as GREATEST/LEAST-NULL, date_diff-boundary, to_char-exists (MEMORY) — verify dialect facts against the 467 source BEFORE asserting the responder is wrong. Git-tag source refuted the run-prompt's prior. Verified verdict reported per instructions.
- Acc 5.0 / Clar 4.75 / App 4.75 / Comp 4.75.

## Overall
(4.8125 + 4.6875 + 4.8125 + 4.8125) / 4 = 19.125 / 4 = **4.7813 — STRONG PASS** (margin +1.281; overall average governs, no per-Q veto).

## Tics — ALL CLEAN
No QUALIFY / false-mechanism-semi-join-mislabel / MAX(varchar) / percent_rank-inversion / **fabricated functions or limitations (Q4 ROLLUP-no-expressions is REAL, source-verified — NOT a fabrication)** / regex-backslash / GREATEST-LEAST-NULL / **DISTINCT-vs-GROUP-BY-perf-folklore (Q3 ABSENT — did NOT recur, one-off confirmed)** / date-minus-integer / broken-secondary-false-justification (Q4 caveat is a TRUE justification, not broken/false) / GROUPING-bitmask-error / mid-churn / column-scope / ILIKE-conflation / INTERVAL-quarter-week. EXTRACT→bigint, integer-div-truncation, DECIMAL-literal-promotion, ROLLUP, GROUPING — all real & verified.

## Scope notes
- **Q1**: EXTRACT(HOUR FROM ts) → bigint, GROUP BY/WHERE usable like Postgres, fields correct. CLEAN.
- **Q2**: integer/integer truncates toward zero (10099/100=100) + `amount/100.0` (100.0 is a DECIMAL literal) → 100.99 + CAST AS DECIMAL alt. CLEAN; only ding = minor "decimal/floating-point" terminology imprecision (it's DECIMAL division specifically, not float) — terminology nit, not a defect.
- **Q3**: `SELECT DISTINCT a,b` == `SELECT a,b GROUP BY a,b` — semantically equivalent, Trino plans identically, no perf winner; responder correctly said "both perform well, pick whichever reads better." **iter989 folklore DID NOT recur (one-off confirmed).** CLEAN.
- **Q4 (KEY)**: ROLLUP lead + GROUPING(region) 0-detail/1-grand-total bitmask CORRECT; **the "ROLLUP works with column names only, not expressions" caveat is VERIFIED CORRECT against trino.io/docs/467 + raw git-tag 467 source ("Only column names are allowed") — NOT a fabricated over-restrictive limitation; the run-prompt's expressions-accepted prior was wrong.** CTE-precompute workaround correct. CLEAN — genuinely strong, complete answer; NO responder slip.

## Recommendation
**DEFAULT NO-OP** (margin +1.281; all 4 deliverables correct & verified both directions; zero tics; zero fabricated functions/limitations; Q3 folklore did NOT recur; Q4 KEY caveat verified TRUE). No findable resource gap, no findability gap, no 2-in-2 recurrence.

Re-probe next sweep:
- (a) another ROLLUP/CUBE/GROUPING SETS Q — confirm column-names-only + CTE-precompute lead holds; watch the INVERSE slip (responder wrongly claiming expressions ARE allowed).
- (b) another date-part bucketing Q (EXTRACT/date_trunc in GROUP BY) — confirm basic-GROUP-BY-accepts-expressions vs ROLLUP-does-not distinction stays sharp.
- (c) another integer-vs-decimal arithmetic Q — confirm integer-div-truncation diagnosis + 100.0-DECIMAL-literal fix; watch the decimal-vs-float terminology drift.
- (d) another DISTINCT-vs-GROUP-BY equivalence Q — confirm folklore stays absent (clean since iter989).

Federation r22 §13.x hard-locked — NOT probed (OVERRIDDEN).
NO resource edits. MUST NOT bump training/state.json (already 1001; passed=true preserved; final_iterations_remaining 0).
