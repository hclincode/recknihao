# Judge Feedback — iter902 (NO-OP durability sweep)

**Verdict: 5.00 STRONG PASS overall** (per-Q 5.00 / 5.00 / 5.00 / 5.00 = 20.00 / 4 = 5.00; margin +1.50; overall average governs, no per-Q veto).
**Federation NOT probed** — the 4.49944/310 federation row is UNCHANGED this iteration.
All 4 answers dialect-clean and doc-verified → **iter903 = DEFAULT NO-OP**.

## Two existence-check verdicts (verified BEFORE judging, iter882 verify-first)

1. **json_array_length EXISTS in Trino 467 — VERDICT: YES.** Verified vs trino.io/docs/467/functions/json.html: `json_array_length(json) -> bigint` — "Returns the array length of json (a string containing a JSON array)"; doc example `SELECT json_array_length('[1, 2, 3]'); -- 3`. It accepts a JSON-array STRING (the `cart` column case). The nested form `json_array_length(json_extract(cart,'$.items'))` is valid because `json_extract` returns a JSON value that `json_array_length` accepts. **Q1 is correct.** (Aside: for a NATIVE Iceberg `ARRAY` column you would use `cardinality()`; the responder correctly treated `cart` as a JSON string and used `json_array_length` — right call.)

2. **left()/right() EXIST in Trino 467 — VERDICT: NO, they do NOT exist.** Verified vs trino.io/docs/467/functions/string.html + WebSearch of the 467 string-function list: Trino 467 has `substring`/`substr` and `upper` but NO `left(string,n)` / `right(string,n)` convenience functions (those are MySQL/SQL-Server/Spark). So the responder's parenthetical aside in Q3 ("Trino does not have a LEFT() function — use SUBSTRING(col,1,N)") is **CORRECT — a bonus accuracy point, NOT an inaccuracy.**

## Per-question scoring (Accuracy / Completeness / Clarity / Actionability)

**Q1 — count items in a JSON array column — 5/5/5/5 (5.00).**
`json_array_length(cart) AS num_items` for `cart = ["prod_1","prod_2","prod_3"]`, plus nested `json_array_length(json_extract(cart,'$.items'))`. VERIFIED correct (see existence verdict 1). Treats the column as a JSON string (correct) and offers the nested path-extract form for arrays buried under a key. Clean, complete, directly usable.

**Q2 — sum margins per product treating negatives as zero, no pre-filter — 5/5/5/5 (5.00).**
`SUM(GREATEST(unit_margin, 0)) ... GROUP BY product_id` floors each value at 0 before summing (no WHERE pre-filter needed) — correct. The responder's WARNING that **GREATEST returns NULL if ANY argument is NULL** in Trino 467 is VERIFIED CORRECT vs comparison.html ("Like most other functions in Trino, they return null if any argument is null" — NOT the Postgres skip-NULL rule), and the fix `SUM(GREATEST(COALESCE(unit_margin,0),0))` is the right guard. A strong, complete answer that anticipates a real footgun. (SUM itself skips NULL rows, so without the COALESCE a NULL `unit_margin` would propagate through GREATEST to NULL and drop that row from the sum; the COALESCE makes the floor-at-zero apply even to NULL inputs, matching the "treat negatives as zero" intent.)

**Q3 — first character uppercased, one expression — 5/5/5/5 (5.00).**
`UPPER(SUBSTRING(company_name, 1, 1)) AS first_letter` — core answer correct and idiomatic. The aside "Trino does not have a LEFT() function — use SUBSTRING(col,1,N)" is CORRECT (existence verdict 2), adding accurate dialect-portability value rather than introducing an error.

**Q4 — % of rows where notes is NULL or '' (blank) — 5/5/5/5 (5.00).**
`SUM(CASE WHEN notes IS NULL OR notes = '' THEN 1 ELSE 0 END)` with `100.0 * ... / COUNT(*)` correctly counts both NULL and empty-string as blank, and the `100.0 *` DECIMAL literal forces non-integer division (avoids the integer-truncate-to-0 trap) — valid in 467. The alternative `COUNT(CASE WHEN notes IS NULL OR notes='' THEN 1 END)` two-column form is also correct (COUNT ignores the NULL ELSE branch, counting only matching rows). Both forms valid and complete.

## Defect / gap scan

**NO genuine findable-but-missing gap and NO dialect defect surfaced.** All four answers are doc-verified correct against trino.io/docs/467 (json/string/comparison .html) + the 467 function list. Both existence claims (json_array_length present, left()/right() absent) are TRUE in 467 — do NOT flag either as wrong in EITHER direction.

## Directive for iter903 (teacher)

**iter903 = DEFAULT NO-OP — teacher ZERO edits.**
- Do NOT add any "wrong" card for Q1–Q4.
- Do NOT mark `json_array_length(cart)` / the nested `json_array_length(json_extract(...))` form wrong (correct).
- Do NOT mark the Q2 GREATEST-returns-NULL-if-any-arg-NULL warning or the `SUM(GREATEST(COALESCE(unit_margin,0),0))` fix wrong (correct).
- Do NOT mark the Q3 "Trino has no LEFT()" aside wrong (correct — 467 truly lacks left()/right()).
- Do NOT churn the json_array_length, GREATEST-NULL/COALESCE, SUBSTRING-first-char, or CASE-blank-percent cards.
- Re-probe fresh adjacents next sweep. **Federation (4.49944/310) is the only un-passed row** — probe ONLY bulletproofed federation angles.
- Do NOT touch any iter534–901 pin. PIN Trino 467. NO federation edits.
- **DO NOT bump training/state.json** (already passed; overall 5.00 PASS holds).

All facts VERIFIED vs trino.io/docs/467 (json/string/comparison .html) + 467 function list via WebFetch/WebSearch 2026-06-10.
