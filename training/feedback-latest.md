# Judge Feedback — iter1063 (2026-06-18)

Stack: Trino 467 + Iceberg + Hive Metastore + MinIO + Spark + dbt-trino + OPA.
Verified BOTH directions against RAW git-tag 467 source + trino.io/docs + WebSearch. Scored against real Trino 467 behavior, NOT resources/.

## Overall: 4.86 PASS (margin +1.36)

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 (array superset / all-elements-present) | 5.0 | 4.75 | 4.75 | 4.875 | 4.84375 |
| Q2 (ROLLUP subtotals + grand total) | 5.0 | 5.0 | 4.75 | 5.0 | 4.9375 |
| Q3 (duration bucket via date_diff) | 5.0 | 4.75 | 4.875 | 4.875 | 4.875 |
| Q4 (% of monthly total via window) | 5.0 | 4.5 | 4.75 | 4.875 | 4.78125 |
| **Overall** | | | | | **4.859375** |

## Q1 — per-row "features contains EVERY element of required set" (4.84)
Both forms are valid Trino 467 and both correctly test "required set is a SUBSET of features".
- `cardinality(array_except(ARRAY['sso','api_access'], features)) = 0`: array_except(x,y) "Returns an array of elements in x but not in y, without duplicates" (array.md). Required elements not found in `features` → empty diff → cardinality 0 → all present. Arg order is correct (required set is x).
- `all_match(ARRAY['sso','api_access'], x -> contains(features, x))`: all_match "Returns whether all elements of an array match the given predicate ... true if all the elements match (special case: empty array)" (array.md). contains(features, x) verified. This is the LEGITIMATE per-row use of all_match — it tests all ELEMENTS of the required-set array against the row's `features` array inside a row-level WHERE clause. Materially different from (and does NOT repeat) the invalid iter1061 Q3 misuse, which put all_match over an UNGROUPED per-row column inside a HAVING/group aggregate (planner error). No regression. Both forms typecheck and return boolean per row.
- Minor: no note on NULL-element 3VL edge (typical string-feature arrays have no NULLs → immaterial).

## Q2 — ROLLUP subtotals + grand total, GROUPING bitmask (4.94)
GROUPING BITMASK VERDICT: 0/1/3 are CORRECT.
- ROLLUP(region, product_category) is equivalent to GROUPING SETS ((region, product_category), (region), ()) — detail, per-region subtotal (product_category NULL), grand total (both NULL) (select.md). Correct.
- GROUPING(region, product_category): "rightmost column = least significant bit ... bit set to 0 if the column is included in the grouping, 1 otherwise" (select.md). So region = MSB (value 2), product_category = LSB (value 1); bit=1 means rolled-up/aggregated-away:
  - Detail (both present): 00 = **0** → 'Detail' OK
  - Region subtotal (region present, category rolled up): 01 = **1** → 'Region Total' OK
  - Grand total (both rolled up): 11 = **3** → 'Grand Total' OK
  - The 10 = 2 case (region rolled up, category present) does NOT occur under ROLLUP — correctly omitted.
- ROLLUP takes plain column names here (region, product_category) — compliant.
- ORDER BY GROUPING(...), region NULLS LAST, product_category NULLS LAST cleanly sorts detail→subtotal→grand and keeps the NULL subtotal/grand rows last within each level. Correct and idiomatic.

## Q3 — duration buckets (4.88)
- date_diff('minute', started_at, ended_at) -> bigint, "timestamp2 - timestamp1 expressed in terms of unit", complete-units / fractional discarded (datetime.md). Correct.
- CASE ladder <1 / <5 / <30 / else evaluates top-to-bottom and correctly maps to Under 1 / 1-5 / 5-30 / Over 30. Boundaries are right (a 5-minute session lands in '5-30', a 30-minute session lands in 'Over 30' — consistent with the half-open reading of the requested bands). width_bucket alternative not needed; CASE is fine and clearer here.

## Q4 — % of month total via window (4.78)
- SUM(revenue) OVER (PARTITION BY month) is a valid window aggregate that repeats the per-month total on every row — correct, no GROUP BY conflict (pure window over an already-aggregated source table monthly_customer_revenue).
- 100.0 is a DECIMAL literal in Trino 467 (undecorated number with a fractional part = DECIMAL; only sci-notation = DOUBLE per types.md). So 100.0 * revenue forces decimal arithmetic — the percentage is computed in decimal, NOT integer-truncated. ROUND(x, 2) valid. Correct.
- WHERE month >= date_trunc('month', current_date) - INTERVAL '12' MONTH: MONTH is a valid INTERVAL qualifier (QUARTER/WEEK would be parse errors; MONTH is fine); date_trunc - INTERVAL date arithmetic is valid. This is a legitimate rolling-12-months filter, NOT a this-vs-last-month off-by-one.
- Minor completeness ding only: no division-by-zero / SUM=0 guard (a month with zero total → divide error/NULL). Noted as minor per directive.

## Cross-cutting
No ::/QUALIFY/false-semi-join/fabricated-fn/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT/over-warning/broken-secondary defects. All secondary forms (Q1 array_except alt) are valid. iter1061 all_match mis-route did NOT recur — Q1's all_match is the correct row-level element-test idiom. iter1058 varchar-to-integer slip not in scope here.

## Recommendation
DEFAULT NO-OP (margin +1.36). No resource edit; no commit. State.json already at 1063 (do not bump).

## Sources verified
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/array.md (array_except, all_match, contains, cardinality)
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/sql/select.md (ROLLUP grouping sets, GROUPING bitmask encoding)
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/datetime.md (date_diff -> bigint, complete units)
- trino.io/docs types.md + WebSearch (decimal literal 100.0 forces decimal arithmetic; integer division truncates)
