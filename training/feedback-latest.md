# Judge Feedback — iter1076 (2026-06-18)

Stack: Trino 467 + Iceberg + Hive Metastore + MinIO + Spark + dbt-trino + OPA.
Verified BOTH directions vs RAW git-tag 467 source (conditional.md / array.md / window.md / language/types.md). Clean sweep, zero source-verified defects.

## Per-question breakdown

### Q1 — sentinel '0' string → NULL so aggregates skip it (don't delete rows)
**Score: 4.81** (Acc 5, Comp 4.75, Clar 5, Act 4.5)
- `NULLIF(plan_type, '0')` is correct. VERIFIED conditional.md: "NULLIF(value1, value2) Returns null if value1 equals value2, otherwise returns value1." So plan_type='0' → NULL, all other values pass through unchanged.
- "NULL is automatically skipped by COUNT/SUM/AVG" is correct (SQL standard aggregate NULL semantics; COUNT(col) and SUM/AVG ignore NULLs).
- Both examples land: the in-aggregate / keep-all-rows form directly satisfies the "don't delete rows" ask; the optional `WHERE NULLIF(...) IS NOT NULL` filter is a valid alternative when row removal IS wanted.
- Minor: one illustrative example applied NULLIF to `customer_id` rather than `plan_type` — illustrative liberty, does not change correctness; tiny completeness/actionability ding only.

### Q2 — number of tags per row (array length)
**Score: 4.94** (Acc 5, Comp 5, Clar 5, Act 4.75)
- `cardinality(tags)` is correct and canonical. VERIFIED array.md: "cardinality(x) Returns the cardinality (size) of the array x," return type bigint.
- Worked example `ARRAY['foo','bar','baz'] → 3` is correct. No `length()`-on-array confusion (length is for varchar). Clean.

### Q3 — top 3 products by revenue per category, cleanly (CRITICAL watch re-probe)
**Score: 4.88** (Acc 5, Comp 5, Clar 4.75, Act 5)
- WINDOW-WRAP VERDICT: CORRECT. Responder wrapped `ROW_NUMBER() OVER (PARTITION BY category ORDER BY SUM(price*quantity) DESC)` in an inner subquery (with `GROUP BY category, product_id`), then filtered `WHERE rank_in_category <= 3` in the OUTER query. This is the required canonical Trino top-N-per-group form.
- Window functions cannot appear in WHERE — per window.md they run after HAVING but before ORDER BY, so they are only legal in SELECT/ORDER BY; filtering on the rank therefore REQUIRES the subquery wrap + outer-WHERE on the alias. Responder did this correctly.
- ROW_NUMBER over the aggregate `SUM(price*quantity)` inside a GROUP BY query is valid — window functions evaluate after GROUP BY/aggregation.
- Confirmed the responder did NOT put the window function directly in WHERE and did NOT reference the rank alias illegally at the same SELECT level. This cleanly contrasts the iter1071 Q4 MERGE window-in-WHERE / alias-in-WHERE slip — the synthesis held this time.
- row_number() returns unique sequential bigint per partition (VERIFIED window.md), so exactly 3 rows per category result; RANK/DENSE_RANK would be the alt if all tied rows should surface (minor unmentioned nuance, not penalized).

### Q4 — users who signed up in last 7 days; Postgres NOW() - INTERVAL '7 days' translation
**Score: 4.81** (Acc 5, Comp 4.75, Clar 5, Act 4.5)
- INTERVAL SYNTAX VERDICT: CORRECT. Responder used `current_date - INTERVAL '7' DAY` (and `current_timestamp - INTERVAL '7' DAY` for timestamps). VERIFIED language/types.md: INTERVAL literals are quoted-number + singular unit keyword (`INTERVAL '2' DAY`, `INTERVAL '3' MONTH`). The Postgres `INTERVAL '7 days'` (plural, unit inside the quotes) is NOT the Trino form — responder correctly translated it.
- `current_date` (date, start of today) and `current_timestamp` exist in 467; `date - INTERVAL '7' DAY` arithmetic is valid and returns a date; `>=` captures the rolling 7-day window. Correct and idiomatic.
- Minor: did not flag that NOW() is itself a Trino-valid alias for current_timestamp (so the Postgres→Trino delta is really only the interval literal, not NOW()). Small completeness note; the recommended query is correct.

## Overall
Overall average = (4.81 + 4.94 + 4.88 + 4.81) / 4 = **4.86**
**PASS** (threshold 3.5; margin +1.36)

No `::`-cast / QUALIFY / false-semi-join / fabricated-fn / regex-backslash / INTERVAL-quarter-week / OFFSET-before-LIMIT / over-warning-folklore / broken-secondary-alternative observed.

## Source-verified dialect notes (RAW 467 URLs checked)
- NULLIF: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/conditional.md — "Returns null if value1 equals value2, otherwise returns value1."
- cardinality: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/array.md — "Returns the cardinality (size) of the array x" (bigint).
- ROW_NUMBER + window execution order: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/window.md — windows run after HAVING, before ORDER BY → not allowed in WHERE → subquery-wrap + outer filter is mandatory; row_number() = unique sequential bigint per partition.
- INTERVAL literal: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/language/types.md — `INTERVAL '3' MONTH` / `INTERVAL '2' DAY` (quoted number, singular unit); Postgres `INTERVAL '7 days'` is not the Trino form.

## Recommendation
DEFAULT NO-OP. All four headline queries are correct and source-verified; the Q3 window-wrap re-probe confirms the iter1071 synthesis slip did not recur on this domain. Q1 customer_id-in-example and Q4 NOW()-alias note are per-instance trivia, NOT resource gaps — do not churn. NO resource edit; NO commit beyond the rubric score line. MUST NOT bump state.json (already 1076).
