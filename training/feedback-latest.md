# Judge Feedback — iter1065 (2026-06-18)

Stack: Trino 467 + Iceberg + Hive Metastore + MinIO + Spark + dbt-trino + OPA.
Verified BOTH directions vs RAW git-tag 467 source (dispositive over rendered HTML) + WebFetch.

## Verdict: PASS — overall average 4.73

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 (JSON-string extract + GROUP BY) | 5.0 | 4.75 | 5.0 | 5.0 | 4.9375 |
| Q2 (>=1 flag from a set, array column) | 5.0 | 5.0 | 5.0 | 5.0 | 5.0 |
| Q3 (today/7/30/older bucketing) | 5.0 | 4.75 | 5.0 | 5.0 | 4.9375 |
| Q4 (pct active per plan, zero/int-div safe) | 4.0 | 4.5 | 4.75 | 5.0 | 4.5625 |
| **Overall** | | | | | **4.734375** |

## Per-question notes (source-verified)

### Q1 — 4.9375
`json_extract_scalar(json, json_path) -> varchar` VERIFIED in raw json.md
("returns the result value as a string"). Accepts a varchar JSON string input
("a string containing JSON") — works directly on a plain-text column, no json_parse
needed. Nested path confirmed: doc example `$.store.book[0].author` proves
`$.device.brand` resolves. GROUP BY guidance CORRECT and important: raw select.md says
GROUP BY accepts "any expression composed of input columns or ... an ordinal number" —
NO mention of SELECT output aliases (#16533). Responder correctly repeated the full
expression AND offered `GROUP BY 1`, and explicitly warned against the alias. Minor
completeness ding only: did not mention NULL behavior on a missing/malformed key
(rows with no `browser` key group under a NULL bucket).

### Q2 — 5.0
`any_match(array(T), function(T,boolean)) -> boolean`, `contains(x, element) -> boolean`,
`array_intersect(x, y) -> array`, `cardinality(x) -> bigint`, `arrays_overlap(x, y) -> boolean`
ALL VERIFIED present in raw array.md. Both forms are semantically correct for "the two
arrays share at least one element":
- `any_match(ARRAY['premium_export','advanced_reports'], x -> contains(feature_flags, x))`
  — for any required flag x, is it present in the row's feature_flags. One row in, one
  boolean out, no UNNEST, no OR chain. Correct.
- `cardinality(array_intersect(feature_flags, ARRAY[...])) > 0` — equivalent. Correct.
`arrays_overlap` (the most direct built-in) would be a third option but its absence is not
a defect; both given forms are valid. Clean, no broken secondary.

### Q3 — 4.9375
`date_diff('day', date, date) -> bigint` VERIFIED returns whole days as bigint. `current_date`
VERIFIED (SQL-standard, no parens, returns date). Casting BOTH sides to date
(`date_diff('day', CAST(created_at AS date), current_date)`) gives true CALENDAR-day
bucketing — more precise than diffing raw timestamps against current_timestamp (which
would count 24h windows, not calendar days). `CAST(timestamp AS date)` is valid. CASE
ladder =0 / BETWEEN 1 AND 7 / BETWEEN 8 AND 30 / ELSE is a legitimate, non-overlapping,
exhaustive bucketing. Minor completeness ding: rows with created_at in the future (clock
skew / pre-dated) would yield a negative diff and fall into ELSE 'older_than_30' — an edge
case not flagged, but not requested.

### Q4 — 4.5625 (CRITICAL literal-type point)
The QUERY IS CORRECT AND SAFE:
`ROUND(100.0 * COUNT(DISTINCT CASE WHEN is_active THEN user_id END) / NULLIF(COUNT(DISTINCT user_id), 0), 2)`
- `NULLIF(COUNT(DISTINCT user_id), 0)` returns NULL when the denominator is zero;
  dividing by NULL yields NULL (not a DIVISION_BY_ZERO error). Correct guard.
- The leading `100.0 *` forces non-integer division, so no integer truncation to 0.
- `ROUND(..., 2)` for readability. The "drop 100.0* for a 0..1 decimal" note is correct.

VERIFIED LITERAL TYPE (raw language/types.md, dispositive): an undecorated decimal-point
literal like `100.0` (doc uses `1.1`) is a **DECIMAL** literal, NOT a DOUBLE. Raw text:
"Exact numeric values can be expressed as numeric literals such as `1.1`, and are supported
by the `DECIMAL` data type." A DOUBLE literal requires scientific notation (`1.03e1`) or the
keyword form (`DOUBLE '10.3'`). Therefore `100.0 * COUNT(...)` is DECIMAL arithmetic and the
division is exact DECIMAL division — STILL CORRECT (non-integer either way, no truncation).

The responder's prose calling this "non-integer (DOUBLE) arithmetic" / implying `100.0` makes
it DOUBLE is a MINOR ACCURACY MISLABEL on an explanatory aside — it does NOT affect query
correctness or output. Small accuracy deduction only (4.0). This is the SAME recurring
100.0-DOUBLE explanatory slip seen iter1063/iter1064; it is per-instance prose, not a query
defect and not a resource defect. Do NOT churn.

(Note: a WebFetch summarizer may claim 100.0 is DOUBLE — I read the raw DECIMAL/DOUBLE
sections of types.md directly; raw source is dispositive and says DECIMAL.)

## Source URLs verified
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/language/types.md (100.0 = DECIMAL, not DOUBLE)
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/json.md (json_extract_scalar -> varchar, nested path, varchar JSON input)
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/array.md (any_match/contains/array_intersect/cardinality/arrays_overlap all present)
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/datetime.md (date_diff -> bigint whole units; current_date)
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/sql/select.md (GROUP BY accepts expr/ordinal, NOT alias; #16533)

## Recommendation
DEFAULT NO-OP. Overall 4.73, margin +1.23 over threshold. No ::/QUALIFY/false-semi-join/
fabricated-fn/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT/over-warning/
broken-secondary. All four LEAD queries are correct Trino 467. The only blemish is the
recurring 100.0-"DOUBLE" prose mislabel on Q4 (query still correct) — per-instance, not a
resource fix. NO resource edit; NO commit. MUST NOT bump state.json (already 1065).
