# iter1088 Judge Feedback — 2026-06-18

Verified BOTH directions vs RAW git-tag 467 source (functions/json.md, functions/math.md, functions/window.md, functions/conversion.md) + WebSearch on CAST/TRY_CAST throw-vs-null semantics. Clean sweep; ZERO source-verified defects.

## Q1 — extract JSON field as plain text — 5.00
`json_extract_scalar(metadata, '$.warehouse') AS warehouse`
- json.md VERIFIED: `json_extract_scalar(json, json_path) -> varchar` — "Like json_extract, but returns the result value as a string (as opposed to being encoded as JSON). The value referenced by json_path must be a scalar (boolean, number or string)." Doc example `json_extract_scalar(json, '$.store.book[0].author')` confirms a varchar-JSON column is accepted directly (no explicit CAST/JSON parse) and that `'$.warehouse'` top-level jsonpath is valid.
- Returns varchar = the requested PLAIN TEXT (json_extract would return JSON-encoded string with quotes; scalar is the correct choice). Returns NULL on missing path — graceful.
- `$.parent.child` nested-path note correct; WHERE-clause filter example correct (varchar='LAX' comparison valid). Accuracy/Completeness/Clarity/Actionability all 5.

## Q2 — absolute difference of two prices — 5.00
`abs(final_price - list_price) AS price_difference`
- math.md VERIFIED: `abs(x)` "Returns the absolute value of x", type-preserving over numeric types. Trivially correct; subtraction order is irrelevant under abs, always non-negative. Engineer knows exactly what to do. All 5.

## Q3 — 4 equal quartile groups with tier label — 4.88
`NTILE(4) OVER (ORDER BY lifetime_spend) AS spend_quartile`
- window.md VERIFIED: ntile(n) is a real window function; "the window frame must not be specified" (OVER with ORDER BY, no frame) — responder's form is exactly correct.
- Bucket distribution VERIFIED: "If the number of rows in the partition does not divide evenly into the number of buckets, then the remainder values are distributed one per bucket, starting with the first bucket." Doc example 6 rows / 4 buckets → `1 1 2 2 3 4` — EARLIER buckets are larger. Responder's "some buckets one row larger" is correct; it did not over-specify which buckets, which is safe (not wrong).
- Correctly answers the explicit "is there a function or must it be CASE WHEN?" — yes, NTILE; no hardcoded thresholds needed. Minor Completeness nicety (not a defect): to attach a TEXT tier label the engineer still wraps NTILE in a CASE (1→'Bronze' etc.) since NTILE yields 1-4 integers; responder gave the integer bucket and named it spend_quartile but did not show the integer→label CASE mapping the question's "label each with their tier" hints at. Mechanic fully correct.

## Q4 — convert TEXT user_id to number in join — 4.88
`JOIN users u ON CAST(e.user_id AS integer) = u.user_id`
- conversion.md VERIFIED: CAST "can be used to cast a varchar to a numeric value type and vice versa" — a clean digit string '10482' casts successfully to integer/bigint.
- Responder's claim that a non-numeric value like 'abc' makes the join FAIL with a conversion error (does NOT silently become NULL) is CORRECT — WebSearch confirms CAST throws on non-numeric varchar; conversion.md's TRY_CAST ("Like cast, but returns null if the cast fails") implies the contrast. Suggesting filtering bad data first is sound.
- Completeness note (NOT an Accuracy deduction per directive): responder omitted TRY_CAST, which returns NULL instead of throwing and is often the cleaner production-safe join key when dirty rows may exist (`TRY_CAST(e.user_id AS integer)` — non-numeric → NULL → simply no join match, no query failure). Mentioning it as the robust alternative would have been ideal. CAST itself is correct, so Accuracy stays 5; the missing TRY_CAST option is a small Completeness/Actionability shortfall. Casting users.user_id direction is also viable but text→number is the cleaner call as given.

## Overall
| Q | Accuracy | Completeness | Clarity | Actionability |
|---|---|---|---|---|
| 1 | 5 | 5 | 5 | 5 |
| 2 | 5 | 5 | 5 | 5 |
| 3 | 5 | 4.5 | 5 | 5 |
| 4 | 5 | 4.5 | 5 | 4.5 |

Per-question averages: Q1 5.00, Q2 5.00, Q3 4.88, Q4 4.88.

**Overall average = 4.94 — PASS** (threshold 3.5, margin +1.44).

**Source-verified defects: ZERO.** No ::/QUALIFY/false-semi-join/fabricated-fn/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT/over-warning/broken-secondary. Two minor Completeness nudges only (Q3 integer→label CASE wrapper; Q4 TRY_CAST robust alternative) — neither is a correctness error.

RECOMMENDATION = DEFAULT NO-OP. NO resource edit; NO commit; NO federation probe. MUST NOT bump state.json.
