# Judge Feedback — iter1080 (2026-06-18)

**Overall average: 4.83 — PASS** (margin +1.33 over 3.5 threshold)

Stack: Trino 467 + Iceberg + Hive Metastore + MinIO + Spark + dbt-trino + OPA.
Verified BOTH directions against RAW git-tag 467 source (dispositive over rendered HTML) plus WebSearch on information_schema.

## Per-question breakdown

### Q1 — inspect a column's data type before math/string ops (CRITICAL re-probe) — 4.88
Responder gave:
- `DESCRIBE payments;` (NO TABLE keyword), and
- `SELECT column_name, data_type FROM information_schema.columns WHERE table_name='payments' AND column_name='gateway_response';`

**VERDICT: CLEAN. The Spark `DESCRIBE TABLE` slip from iter1079 did NOT recur.**
- `sql/describe.md` synopsis is exactly `DESCRIBE table_name` (no TABLE keyword) and states "DESCRIBE is an alias for SHOW COLUMNS." The responder's bare-table form is valid Trino 467.
- `information_schema.columns` is queryable and exposes `column_name` and `data_type` (confirmed via WebSearch; columns include table_catalog/table_schema/table_name/column_name/ordinal_position/column_default/is_nullable/data_type). The projection and WHERE filter are valid.
- This directly closes the iter1079 Q1 re-probe: iter1079 wrongly used `DESCRIBE TABLE iceberg.schema.users` and claimed it "works in Spark SQL or Trino 467" (TABLE is reserved → parse error). This iteration the responder used the correct no-TABLE form AND offered the information_schema alternative. Confirmed from the 2nd angle.
- Source: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/sql/describe.md

### Q2 — every 10th row by row number — 4.69
`SELECT * FROM (SELECT t.*, ROW_NUMBER() OVER (ORDER BY page_view_id) AS rn FROM page_views t) WHERE MOD(rn, 10) = 0;`
- **Query CORRECT.** `row_number() -> bigint` exists (window.md). Window functions execute after HAVING and before ORDER BY, so they CANNOT appear in WHERE — the subquery wrap + outer-WHERE filter is exactly required. `MOD(rn,10)=0` selects every 10th row.
- **MINOR over-optimistic perf aside (flagged, NOT a correctness issue):** the claim "reads/filters efficiently without materializing the full table first" is mildly misleading — `ROW_NUMBER() OVER (ORDER BY page_view_id)` requires a global sort, so the engine scans and sorts the data; there is no partition/predicate that lets it skip rows up front. Accuracy docked slightly only for the perf framing. This is the recurring "responder over-optimistic perf aside" pattern; per-instance, NOT a resource gap.
- Source: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/window.md

### Q3 — pair two arrays element-by-element — 4.88
`zip_with(tags, promo_tags, (tag, promo) -> ROW(tag, promo))` + alternative `map(tags, promo_tags)`.
- **CLEAN.** array.md: `zip_with(array(T), array(U), function(T,U,R)) -> array(R)` merges element-wise via the lambda; the lambda building `ROW(tag, promo)` yields an array of ROW pairs — exactly the ask.
- The alternative `map(array(K), array(V)) -> map(K,V)` "Returns a map created using the given key/value arrays" is a valid 467 constructor (first array = keys, second = values), correctly described.
- WORTH NOTING (not penalized): `zip(array1, array2) -> array(row)` is the simpler, more direct element-wise pairer for this exact task (`zip(ARRAY[1,2], ARRAY['a','b']) -> [ROW(1,'a'), ROW(2,'b')]`) and would be the most idiomatic single-function answer. The responder's zip_with form is correct and equivalent; zip would be marginally cleaner. Minor caveat on the map alternative: it errors on duplicate keys; both zip/zip_with pad uneven lengths with NULL.
- Source: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/array.md and .../functions/map.md

### Q4 — label priority 1/2/3 as low/medium/high — 4.88
`CASE WHEN priority=1 THEN 'low' WHEN priority=2 THEN 'medium' WHEN priority=3 THEN 'high' END AS priority_label`
- **CLEAN.** conditional.md: searched-form CASE is valid 467; with no ELSE, unmatched values return NULL ("the result from the ELSE clause is returned if it exists, otherwise null is returned"). Display-only relabel without mutating data — exactly the ask.
- Source: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/conditional.md

## Source-verified dialect notes
- DESCRIBE 467 synopsis = `DESCRIBE table_name` (NO TABLE keyword), alias of SHOW COLUMNS — responder correct; Spark `DESCRIBE TABLE` form (iter1079 defect) did NOT recur.
- ROW_NUMBER cannot be in WHERE → subquery-wrap mandatory; responder correct. Perf aside over-optimistic (global sort required).
- zip / zip_with / map(keyArray, valueArray) all valid 467; zip is the simplest direct pairer.
- Searched CASE with no ELSE → NULL on unmatched; correct.

No ::/QUALIFY/false-semi-join/fabricated-fn/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT/over-warning/broken-secondary defects.

## Recommendation
**PASS (4.83).** DEFAULT NO-OP — no resource edit, no commit warranted. The Q1 re-probe confirms the iter1079 Spark-DESCRIBE-TABLE slip was a per-instance slip, not a resource gap; canonical column-type-inspection now answered correctly from the 2nd angle. Q2 perf aside and Q3 zip-vs-zip_with idiom are per-instance trivia, do NOT churn. MUST NOT bump state.json (already 1080).
