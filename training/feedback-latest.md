# Judge Feedback — iter1071 (2026-06-18)

**Overall average: 4.20 — PASS** (threshold 3.5; overall average governs, no per-question veto)

Stack: Trino 467 + Iceberg + Hive Metastore + MinIO + Spark + dbt-trino + OPA.
Verified BOTH directions against RAW git-tag 467 source (dispositive over rendered HTML).

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 cume_dist percentile | 5.0 | 4.5 | 4.75 | 4.75 | 4.75 |
| Q2 safe map read | 3.0 | 4.5 | 4.0 | 4.75 | 4.0625 |
| Q3 dbt incremental | 4.75 | 4.75 | 4.75 | 4.75 | 4.75 |
| Q4 MERGE upsert | 2.5 | 3.5 | 4.0 | 3.0 | 3.25 |
| **Overall** | | | | | **4.20** |

---

## Q1 — percentile standing by mrr (cume_dist) — 4.75

`ROUND(cume_dist() OVER (ORDER BY mrr) * 100, 1)` is correct and the cume_dist-vs-percent_rank
distinction is accurate.

Source-verified (RAW window.md):
- cume_dist(): "the number of rows preceding or peer with the row in the window ordering ...
  divided by the total number of rows in the window partition." → fraction at-or-below; the row
  is always a peer of itself, so the result is NEVER 0 (matches responder's claim).
- percent_rank() = (r-1)/(n-1) → the top/first row gets exactly 0.0 (matches responder's
  reason for preferring cume_dist for percentile labels).

Minor: with `ORDER BY mrr` ascending, the highest earner gets the highest percentile, so
"top 15%" = `percentile_by_mrr >= 85`. The answer leaves that final filter implicit. No
accuracy issue.

Source: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/window.md

## Q2 — safe map read when key may be missing — 4.0625

Core recommendation CORRECT: `element_at(properties,'country')` is the NULL-safe form;
`element_at` returns NULL on a missing key, WHERE drops the NULL row, no error. Existence
helpers (`element_at(...) IS NOT NULL`, `contains(map_keys(properties),'country')`) are valid.

**ACCURACY DEFECT (the precise point asked):** The explanation says "When you access a map with
`properties['country']` ... and the key is missing, Trino returns NULL, which can cause issues."
This is a factual MISLABEL. Source-verified (RAW map.md):
- Subscript `m['key']`: "This operator throws an error if the key is not contained in the map."
  → it THROWS, it does NOT return NULL.
- `element_at(map, key)`: "Returns value for given key, or NULL if the key is not contained in
  the map." → returns NULL.

The subscript THROWS on a missing key — which is exactly what the user reported ("sometimes
errors when the key is missing"). The responder's own framing ("returns NULL, which can cause
issues") contradicts both the docs and the user's symptom. The right framing: the subscript
THROWS; element_at returns NULL, which is why element_at is the fix. The recommendation lands;
the diagnosis sentence is wrong → accuracy ding.

Source: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/map.md

## Q3 — dbt incremental model, only process new rows — 4.75

Sound, idiomatic dbt-trino incremental pattern. `materialized='incremental'`,
`incremental_strategy='merge'`, `unique_key='event_id'`, and Iceberg `partitioning` property
are all real dbt-trino configs. `{% if is_incremental() %}` is the correct Jinja guard,
`{{ this }}` is the correct self-reference, and the MAX-timestamp high-watermark
(`WHERE created_at >= (SELECT COALESCE(MAX(created_at), TIMESTAMP '1970-01-01') FROM {{ this }})`)
is a standard incremental idiom. `date_add('day',-3,...)` lookback for late-arriving data is a
reasonable refinement. No defects.

## Q4 — MERGE upsert one row per customer (latest plan) — 3.25

The MERGE skeleton and the Trino-specific notes are CORRECT and source-verified:
- `MERGE INTO t USING s ON ... WHEN MATCHED THEN UPDATE SET ... WHEN NOT MATCHED THEN INSERT ...`
  is valid Trino 467 (RAW sql/merge.md).
- No `UPDATE SET *` shorthand — explicit column assignments required (verified; docs show
  explicit `UPDATE SET col = s.col`).
- First-match-wins: "the WHEN clauses are processed in order. Only the first matching WHEN
  clause is executed"; "The query fails if a single target table row matches more than one
  source row" (verified).
- MERGE on Iceberg requires format version 2 ("Version 2 is required for row level deletes";
  v2 is also the 467 default) — correct.

**CRITICAL DEFECT (lead query fails to plan):** The USING subquery is
`SELECT customer_id, plan_type, effective_from,
  ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY effective_from DESC) = 1 AS is_latest
  FROM subscription_changes WHERE is_latest`.
This is INVALID for two independent reasons:
1. A window function (ROW_NUMBER) cannot appear in a WHERE clause. Window functions run AFTER
   HAVING and before ORDER BY (RAW window.md), i.e. strictly after WHERE evaluates — so a
   window result is not available to WHERE.
2. `is_latest` is a SELECT-list alias referenced in the WHERE of the SAME query. Trino does not
   resolve SELECT aliases in WHERE (only ORDER BY sees them) — same #16533 family that recurs
   in this loop.

Correct form: compute ROW_NUMBER in an inner subquery/CTE projecting it as a column, then filter
in the OUTER query:
```
USING (
  SELECT customer_id, plan_type, effective_from
  FROM (
    SELECT customer_id, plan_type, effective_from,
           ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY effective_from DESC) AS rn
    FROM subscription_changes
  ) WHERE rn = 1
) s
```
This is the same top-1-per-group wrapping the responder got RIGHT in iter1066 Q4, so it is a
synthesis slip here, not a missing concept. Re-probe Q4 from a 2nd angle.

Sources:
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/sql/merge.md
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/window.md
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/connector/iceberg.md

---

## Verdict & recommendation

PASS at 4.20 (margin +0.70). Two clean answers (Q1, Q3), one accuracy-mislabel (Q2 subscript
"returns NULL" → actually THROWS), one lead-query defect (Q4 window-in-WHERE / alias-in-WHERE).

- Q2: the subscript-vs-element_at NULL/THROW direction is a recurring, findable distinction
  (see iter1070 Q1 where the responder got it RIGHT: subscript THROWS, element_at→NULL). Here it
  inverted the subscript behavior in prose while still recommending element_at. Per-instance
  re-probe of the "missing-map-key behavior" framing; the resource canonical is already correct,
  so this is a responder slip, not a resource gap — do NOT churn.
- Q4: window-in-WHERE / SELECT-alias-in-WHERE is the #16533 + window-placement family. The
  responder demonstrably knows the outer-subquery wrapping (iter1066 Q4). This is a synthesis
  slip on a novel domain, not a missing canonical. Re-probe Q4 2nd angle; no resource edit.

MUST NOT bump state.json (already iter1071).
