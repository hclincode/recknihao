# Judge Feedback — iter1064 (2026-06-18)

**Overall: 4.82 / 5 — PASS** (threshold 3.5; margin +1.32)

Stack: Trino 467 + Iceberg + Hive Metastore + MinIO + Spark + dbt-trino + OPA.
Verified BOTH directions against RAW git-tag 467 source
(raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/) and trino.io/docs/467.
Scored against real Trino 467 behavior, NOT resources/.
Sources checked:
- functions/datetime.md (date_diff, current_timestamp, now)
- functions/json.md (json_extract_scalar, json_extract, JSON_VALUE)
- functions/array.md (array_intersect, cardinality, any_match, contains, arrays_overlap)
- language/types.md (numeric literal typing — DECIMAL vs DOUBLE)
- functions/math.md (division operator)
- Memory pins: reference_trino_division_by_zero (git-tag-verified), reference_trino_timestamp_tz_coercion.

---

## Q1 — recency bucketing (today/this week/this month/older) — 4.75

Query CORRECT. `date_diff('day', occurred_at, current_timestamp)` verified to return
`timestamp2 - timestamp1` as a **bigint** day count (datetime.md). CASE ladder
`=0` / `BETWEEN 1 AND 6` / `BETWEEN 7 AND 30` / `ELSE` maps the four buckets correctly,
top-to-bottom (mutually exclusive, no overlap). `current_timestamp` (no parens) and `now()`
both valid; `now()` is documented as an alias for `current_timestamp`. current_timestamp
returns **timestamp WITH TIME ZONE**, and mixing it with the plain-timestamp `occurred_at`
is NOT a type error — implicit TIMESTAMP→TIMESTAMP WITH TIME ZONE coercion exists in 467
(git-tag TypeCoercion.java). Postgres-likeness addressed well.

- Accuracy 4.75 / Completeness 4.5 / Clarity 4.75 / Actionability 5.0
- Caveat (completeness only): `date_diff('day', ...)` counts complete ~24h day-units, not a
  calendar-date difference — e.g. 23:00 yesterday vs 01:00 today = 0 → labeled "today".
  A legitimate approximation for this use; worth a one-line note but not a defect.

## Q2 — extract browser from JSON string, GROUP BY it — 4.97

Fully correct. `json_extract_scalar(properties, '$.browser')` exists, operates on a varchar
JSON string, and returns VARCHAR (json.md). GROUP BY correctly **repeats the expression**
(not a SELECT alias) — avoids the #16533 GROUP-BY-alias trap. NULL on missing/malformed
accurate. `json_extract` for nested objects and
`JSON_VALUE(col,'$.key' RETURNING varchar NULL ON EMPTY NULL ON ERROR)` are valid Trino 467
SQL/JSON syntax (RETURNING + ON EMPTY/ON ERROR confirmed in json.md). Thorough.

- Accuracy 5.0 / Completeness 5.0 / Clarity 4.875 / Actionability 5.0

## Q3 — arrays sharing at least one element — 4.94

Both forms correct. `cardinality(array_intersect(tags, ARRAY['promo','flash_sale'])) > 0`
and `any_match(ARRAY['promo','flash_sale'], x -> contains(tags, x))` verified — array_intersect,
cardinality, any_match, contains all exist (array.md). The explicit warning that
`array_intersect` is a within-row function on two array values and must NOT be confused with
the `INTERSECT` set operator (across rows) is exactly right and valuable.

- Accuracy 5.0 / Completeness 4.75 / Clarity 5.0 / Actionability 5.0
- Completeness ding only: `arrays_overlap(tags, ARRAY[...])` is a valid, more-direct option
  for the exact "share any element" test and went unmentioned. Given forms are correct.

## Q4 — safe active-percentage per plan (CRITICAL fine point) — 4.625

The QUERY is CORRECT and SAFE:
`ROUND(100.0 * COUNT(CASE WHEN is_active THEN 1 END) / NULLIF(COUNT(*), 0), 2)`.
`NULLIF(COUNT(*),0)` turns a zero denominator into NULL so the division returns NULL rather
than raising — verified-correct guard. Multiplying by `100.0` forces non-integer division so
there is no integer truncation.

**VERIFIED literal-type verdict:** `100.0` is a **DECIMAL literal**, NOT a DOUBLE.
types.md DECIMAL section: "Exact numeric values can be expressed as numeric literals such as
`1.1`, and are supported by the `DECIMAL` data type." Only scientific-notation literals
(`1.03e1`) or the `DOUBLE '...'` keyword form yield DOUBLE. So the responder's explanatory
label "DOUBLE literal" and "forces the numerator to DOUBLE" is WRONG — the arithmetic is
exact DECIMAL division. (A WebFetch summarizer initially claimed `100.0` is DOUBLE; reading
the raw DECIMAL/DOUBLE sections directly refuted it. The summarizer misread.)

Crucially, **the query is correct regardless** — DECIMAL division is also non-integer, so
there is no integer truncation either way; only the explanatory aside is mislabeled.

The other claim is CORRECT: in Trino, INTEGER/DECIMAL division by zero raises
DIVISION_BY_ZERO, while DOUBLE/REAL division by zero returns Infinity/NaN per IEEE-754
(git-tag-verified, reference_trino_division_by_zero pin; r27 §4.4H locked).

- Accuracy 4.0 / Completeness 4.75 / Clarity 4.75 / Actionability 5.0
- Per directive: only a small accuracy deduction for the literal-type mislabel on an
  explanatory aside; the SQL produces correct, safe results.

---

## Watchlist (none triggered)
No `::`/QUALIFY/false-semi-join/fabricated-fn/regex-backslash/INTERVAL-quarter-week/
OFFSET-before-LIMIT/over-warning/broken-secondary. All secondary forms (any_match, json_extract,
JSON_VALUE) are valid. The iter1058/1063 `100.0`-literal-type question recurs as a responder
EXPLANATION slip (mislabeled DOUBLE) but the query is correct — per-instance, not a resource
defect; do not churn.

## Recommendation
DEFAULT NO-OP (margin +1.32). Q4 "100.0 = DOUBLE literal" is the only inaccuracy and is on an
aside, not the SQL. If the teacher wants a near-zero-cost tightening, a one-line note that
undecorated decimal-point literals are DECIMAL (not DOUBLE) would close the recurring
explanation slip — but it is not failure-causing. NO resource edit required; NO commit.
MUST NOT bump state.json (already 1064).
