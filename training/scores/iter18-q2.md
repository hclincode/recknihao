# Score: Iteration 18, Question 2

**Date**: 2026-05-24
**Phase**: Final
**Question**: Our Postgres events table has a JSONB properties column with different keys per event type. It's hard to query in analytics. How should we handle it?
**Rubric topics**: Postgres-to-Iceberg ingestion (JSONB / schema design); Schema design for analytics

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.50 | Two options (string storage vs. flatten hot fields) correctly described. get_json_object() for Spark extraction is correct. properties_raw fallback pattern is correct and practical. overwritePartitions() for idempotency — correct, consistent with iter17. Minor inaccuracy: answer says "backfill old rows with one Spark job" after adding a new column — in Iceberg, old Parquet files without the column automatically return NULL at query time, no backfill needed unless the engineer wants non-NULL historical values. This could mislead engineers into thinking backfill is required. |
| Beginner clarity | 4.75 | Two-option structure (simple-but-slow vs recommended) is clear. Code example for Spark extraction is directly usable. "Rule of thumb: flatten what you GROUP BY, WHERE, or JOIN ON" is the right heuristic. |
| Practical applicability | 4.75 | Spark + get_json_object + overwritePartitions + Iceberg — all correct for production stack. The before/after SQL comparison (json_extract_scalar vs direct column reference) demonstrates the benefit concretely. |
| Completeness | 4.75 | Covers both approaches, trade-offs, implementation, what to flatten, why columnar benefits. References resources/09-lakehouse-schema-design.md MAP<VARCHAR,VARCHAR> as an alternative — valid bonus content. |
| **Average** | **4.69** | |

---

## What the answer got right

1. String storage (simple, flexible, slower) vs. flatten hot fields (faster, partition-prunable, columnar-compressed) — correct contrast.
2. get_json_object() for Spark JSONB extraction — correct API.
3. properties_raw fallback — correct pattern for keeping raw data.
4. overwritePartitions() over append() — correctly recommended for idempotency.
5. Compression benefit from flattening (dictionary encoding for low-cardinality fields) — accurate.

## What the answer missed / got wrong

1. **"Backfill old rows" claim.** When a new column is added to Iceberg via ALTER TABLE ADD COLUMN, old Parquet files return NULL for that column automatically — no Spark backfill is needed. The backfill is only needed if the engineer wants historical rows to have non-NULL values. The answer says "run a Spark job to backfill" as if it's required — this is misleading.

## Resource note

`resources/13-postgres-to-iceberg-ingestion.md` should clarify in the schema evolution section: "Adding a column via ALTER TABLE ADD COLUMN is metadata-only — old rows return NULL automatically at query time. Only run a backfill job if you specifically need non-NULL values in historical records."

## Topic score updates

**Postgres-to-Iceberg ingestion**
- Prior after Q1 this iter: 4.019 across 13 questions
- This answer: 4.69 (14th angle — JSONB flattening)
- Running avg: (52.247 + 4.69) / 14 = **4.067** across 14 questions
- Status: PASSED (crossed 4.0 milestone)
