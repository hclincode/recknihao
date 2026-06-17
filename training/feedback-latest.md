# iter1027 Judge Feedback

**OVERALL: 4.6875 / 5 — PASS** (75.0/16; margin +1.1875 above 3.5 threshold)
OVERALL AVERAGE governs — no per-question veto. All 4 answers verified BOTH directions against trino.io/docs/467 (functions/json.html, functions/conversion.html, functions/conditional.html, functions/datetime.html, functions/window.html) + WebSearch on json_extract_scalar non-scalar→NULL — NOT resources/. Prod stack (Trino 467 + Iceberg + MinIO + HMS, on-prem k8s) all 4 fit; no federation/auth angle this sweep.

## Per-question scores

### Q1 — nested JSON browser name — 4.8125 CLEAN
Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75
- `json_extract_scalar(properties, '$.browser.name')` → VARCHAR scalar leaf. VERIFIED functions/json.html: "returns the result value as a string... The value referenced by json_path must be a scalar (boolean, number or string)." Nested dotted path `$.a.b` works (docs ship `$.store.book[0].author`).
- "NULL if path resolves to object/array" CORRECT — legacy json_extract_scalar (JSONPath-like family) returns NULL on non-scalar (WebSearch + discussion #19197). This is the legacy fn (not the SQL/JSON `json_value` which errors); responder's claim matches the legacy fn it used.
- `json_extract` returns JSON (objects/arrays) — CORRECT.
- `json_exists(properties, 'strict $.browser.name')` → boolean key-presence, strict mode supported — CORRECT.

### Q2 — skip/null bad unit_price rows — 4.8125 CLEAN
Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75
- `TRY_CAST(unit_price AS DECIMAL(18,2))` → NULL on bad input vs CAST throws. VERIFIED functions/conversion.html: "Like cast(), but returns null if the cast fails."
- `try(expr)` catches divide-by-zero / invalid-cast-or-function-arg / numeric-out-of-range → NULL. VERIFIED functions/conditional.html (three documented categories; JSON-error mention is a benign over-listing, the core three are exact).
- `COALESCE(TRY_CAST(...), 0)` default — CORRECT and idiomatic (docs explicitly pair try with COALESCE).

### Q3 — events per week, weeks with >= 50 events — 4.71875 CLEAN
Acc 5 / Comp 4.625 / Clar 4.75 / App 4.75
- `date_trunc('week', event_date)` → Monday-start week bucket. VERIFIED functions/datetime.html (example truncates 2001-08-22 → 2001-08-20, a Monday).
- GROUP BY repeats the `date_trunc(...)` expr (alias not resolvable in GROUP BY) — CORRECT.
- `HAVING COUNT(*) >= 50` filters AFTER aggregation; `>=` correct for "at least 50" (boundary not slipped to `>`). WHERE-vs-HAVING distinction stated correctly (WHERE pre-aggregation, HAVING post-aggregation). CTE variant valid.

### Q4 — each row alongside total session count — 4.8125 CLEAN
Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75
- `COUNT(*) OVER ()` (empty OVER) → whole-table count attached to every row, no row collapse. VERIFIED functions/window.html: "All Aggregate functions can be used as window functions by adding the OVER clause"; empty frame = whole result set.
- `CONCAT('Session ', ROW_NUMBER() OVER (ORDER BY session_id), ' of ', COUNT(*) OVER ())` label — ROW_NUMBER() OVER (ORDER BY ...) VERIFIED (unique sequential from 1).
- "window functions don't collapse vs GROUP BY" distinction CORRECT.

## TICS check — CLEAN
No `::` cast anywhere (all 4). No QUALIFY, no false semi-join, no fabricated functions (json_extract_scalar/json_extract/json_exists/TRY_CAST/try/date_trunc/COUNT-OVER/ROW_NUMBER all real & verified). No regex-backslash, INTERVAL-quarter-week, OFFSET-before-LIMIT, generate_subscripts, or broken-secondary slip this iter. NO DEFECTS — all 4 fully correct and verified both directions.

## RECOMMENDATION = DEFAULT NO-OP
Margin +1.1875; all 4 clean; all four targeted checks resolved in the responder's favor. No source-verified findable gap, no resource defect, no 2-in-2 consecutive recurrence. NO resource edit; NO FIX-A; NO git commit (orchestrator commits once after judge). MUST NOT bump state.json (already 1027).

## Re-probe (monitor only, next sweep)
- (a) nested JSON: json_extract_scalar→VARCHAR scalar / NULL-on-non-scalar, json_extract→JSON, json_exists→boolean strict-mode — watch json_value-vs-json_extract_scalar error-vs-NULL confusion.
- (b) error-tolerant casts: TRY_CAST→NULL-on-fail vs CAST-throws, try() three categories, COALESCE default — watch try() over-listing of caught error types.
- (c) date_trunc('week') Monday-start + HAVING-post-aggregation `>=`-for-"at least" boundary (watch > vs >= slip) + WHERE-vs-HAVING.
- (d) COUNT(*) OVER () whole-table-no-collapse + ROW_NUMBER() OVER (ORDER BY) label — watch window-vs-GROUP-BY collapse confusion.

Federation r22 §13.x hard-locked, NOT probed (stays 4.49944/310).
