# Judge Feedback — iter1028

**OVERALL: 4.640625 / 5** (74.25/16) — **PASS** (threshold 3.5; margin +1.140625)
OVERALL AVERAGE governs — no per-question veto.

Verified BOTH directions against trino.io/docs/467 (functions/json.html, functions/comparison.html, functions/array.html, functions/conditional.html, sql/select.html) + WebSearch (COALESCE mixed-numeric coercion) — NOT resources/. Prod stack (Trino 467 + Iceberg + MinIO + Hive Metastore) fits all 4; no federation/auth angle.

## Per-question scores

| Q | Topic | Acc | Comp | Clar | App | Avg |
|---|---|---|---|---|---|---|
| Q1 | json_array_length (tags count) | 5.0 | 4.75 | 4.75 | 4.75 | 4.8125 |
| Q2 | all_match prefix-validation (KEY) | 3.0 | 4.0 | 4.25 | 4.25 | 3.875 |
| Q3 | COALESCE mixed numeric types | 5.0 | 4.75 | 4.75 | 4.625 | 4.78125 |
| Q4 | zip → array(ROW) | 4.25 | 4.5 | 4.5 | 4.75 | 4.5 |

## Resolved verdicts (with citations)

**Q1 — CLEAN.** `json_array_length(json_extract(properties,'$.tags'))` is correct. `json_array_length` exists, takes a JSON array, returns bigint (functions/json.html). `json_extract(json, path)` returns JSON, so extract-the-nested-array-first then count is right; bare top-level array → `json_array_length(col)` directly. Both branches accurate.

**Q2 (KEY) — DEFECT: LIKE underscore is a wildcard.** The `all_match(enabled_flags, flag -> ...)` structure is fully correct: `all_match(array(T), function(T,boolean)) -> boolean` returns true iff the predicate holds for ALL elements, works on the array in-place (no UNNEST), and the `array_except` subset aside is real and valid (functions/array.html). BUT the inner predicate `flag LIKE 'ff_%'` is BUGGY. In SQL `LIKE`, `_` is the single-character WILDCARD (comparison.html: "`_` matches any single character"), so `'ff_%'` matches "ff" + ANY one char + any rest — e.g. "ffxtest", "ffabc", "ff9" all pass. It does NOT require a LITERAL underscore as the 3rd character, so it is WRONG for validating a literal `"ff_"` prefix.
Correct forms:
- `starts_with(flag, 'ff_')` — literal, no wildcard interpretation (functions/string.html), or
- `flag LIKE 'ff\_%' ESCAPE '\'` — escaped underscore (ESCAPE clause confirmed in comparison.html).
**Classification: responder slip** (imported habit that LIKE `_` is literal). Not a findable resource gap — no resource asserts `LIKE 'x_'` is literal. 1st occurrence → per-instance monitor, NOT 2-in-2, NO FIX-A.

**Q3 — CLEAN.** `COALESCE(amount_usd, amount_eur, amount_gbp)` across DOUBLE/DECIMAL/BIGINT works. Trino finds a common numeric SUPER-TYPE within the numeric family and does NOT error on mixed numerics (conditional.html first-non-null + WebSearch confirms implicit numeric coercion; only possible precision loss). The contrast is accurate: Trino is strict elsewhere — `int = varchar` → TYPE_MISMATCH, and `||` concat has no numeric auto-cast (VARCHAR-only). `CAST(DOUBLE AS DECIMAL)` HALF_UP also correct.

**Q4 — minor access-pattern off.** `zip(metric_names, metric_values)` → `array(row(T,U))` element-wise merge is VERIFIED (array.html: "Merges the given arrays, element-wise, into a single array of rows"). The `map(keys, values)` 2-arg constructor aside is correct (requires unique, non-null keys). DEFECT (minor): the extraction snippet `CROSS JOIN UNNEST(zip(...)) AS t(pair)` then `pair.col0 / pair.col1` is OFF. UNNEST of an `array(row(...))` EXPANDS the row fields into SEPARATE columns (sql/select.html: UNNEST with an ARRAY of ROW structures expands each field of the ROW into a corresponding column). The correct form is `AS t(name, value)` then `SELECT name, value` — not a single `pair` row accessed via `pair.col0`. zip itself and the map aside are fully correct; only the UNNEST-access detail slipped.
**Classification: per-instance access-pattern slip** (UNNEST-of-array(row) expands fields, not a row-typed column). 1st occurrence monitor, NOT 2-in-2.

## TICS
`::` absent all 4. Clean except Q2 LIKE-underscore + Q4 UNNEST-row-access. No QUALIFY / false-semi-join / fabricated-fn (json_array_length, json_extract, zip, all_match, array_except, COALESCE, map, starts_with all real & verified) / regex-backslash / INTERVAL-quarter-week / OFFSET-before-LIMIT / generate_subscripts / broken-secondary.

## Recommendation: DEFAULT NO-OP
Margin +1.140625. 2/4 clean (Q1, Q3 resolved in responder's favor). Q2 and Q4 are both per-instance responder slips on FIRST occurrence — neither is a findable resource gap and neither is a 2-in-2 recurrence. No resource edit, no FIX-A, no git commit (orchestrator commits once after judge).

Re-probe (monitor only):
- (a) prefix-validation — watch `LIKE 'x_%'` literal-underscore relapse; if 2-in-2 → LIGHT nudge (LIKE `_` = wildcard; use `starts_with(s,'x_')` or `LIKE 'x\_%' ESCAPE '\'`).
- (b) `zip` → array(row) + UNNEST-of-array(row) EXPANDS fields `AS t(a,b)` NOT `pair.col0`; watch relapse.
- (c) json_array_length nested extract-first vs bare-array.
- (d) COALESCE common-numeric-super-type vs strict `int=varchar` / `||` no-coercion.

Federation r22 §13.x hard-locked, NOT probed (4.49944/310). MUST NOT bump state.json (already 1028).
