# Score: iter55-q2

**Topic**: Postgres-to-Iceberg ingestion
**Score**: 5.0 / 5.0

## Dimension scores
- Completeness: 5/5
- Accuracy: 5/5
- Clarity: 5/5
- No hallucination: 5/5

## What the answer got right
- Confirms Parquet has no native JSON/JSONB type and conversion happens at ingest time (implicit: "Parquet has no native JSON type, so this works technically" when discussing the VARCHAR option).
- Option 1 (VARCHAR string): correctly described with `json_extract_scalar(properties, '$.feature_name')` Trino function and the right downside framing — JSON re-parsed on every query, no columnar compression benefit on the inner fields.
- Option 2 (extract hot fields): correctly recommended, with runnable Spark `get_json_object("properties", "$.feature_name")` code that uses the engineer's own example fields (`feature_name`, `plan_type`); blob preserved as `properties_raw VARCHAR` via `withColumnRenamed`.
- "Rule of thumb: extract anything you GROUP BY, WHERE, or JOIN ON. Leave the rest in `properties_raw`" — verbatim from the resource, exactly what the engineer needs.
- Array handling fully covered: index-based extraction via `get_json_object("properties", "$.tags[0]")` for single element AND `from_json` + `array_contains` for membership checks, with the concrete "enterprise vs enterprise-plus" substring-match anti-example that makes the danger immediate.
- Schema evolution closer addresses the natural next question: `ALTER TABLE ... ADD COLUMN` is metadata-only (millisecond), old rows return NULL automatically, no backfill required — exactly matching the resource and Iceberg spec.
- Closes with a "why this matters" paragraph that ties back to dashboard speed, file skipping, and new analyst onboarding — practical applicability for a SaaS team.

## What the answer missed or got wrong
- Very minor: the array-membership code block uses `col("tags_array")` but the `col` import isn't shown in the snippet (it's imported in the earlier resource example but not in this answer's snippet). An engineer copy-pasting would catch and fix instantly — not material.
- "Columnar compression" mentioned but not glossed inline — context makes it clear enough, not a real deduction.

## Recommendation for teacher
No resource change required for this answer. The resource section on JSONB handling (`resources/13-postgres-to-iceberg-ingestion.md` lines ~467-513) is doing its job — responder pulled every expected point cleanly. If the teacher wants a polish pass, the array_contains snippet in the resource could add the missing `from pyspark.sql.functions import col` line so any future copy-paste is fully self-contained.
