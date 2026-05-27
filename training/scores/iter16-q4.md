# Score: Iteration 16, Question 4

**Date**: 2026-05-24
**Phase**: Final
**Question**: Our data engineer added a new column `device_type` to our analytics events table without rewriting historical data — old rows show NULL automatically. In Postgres, adding a column can be slow. What makes the analytics storage different?
**Rubric topics covered**: Column-oriented storage; What a data lakehouse is and how it differs from a warehouse

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.25 | Core Iceberg + Parquet schema evolution mechanism correctly explained: metadata-only ADD COLUMN, column-ID-based tracking (not position-based), old files missing the column → Trino auto-fills NULL, new files have actual values. Minor inaccuracy: "In Postgres, ALTER TABLE ADD COLUMN must rewrite every single row on disk." Since PostgreSQL 11, adding a nullable column (no default or a constant default) is O(1) — it's metadata-only. Postgres does NOT always rewrite rows for ADD COLUMN. The answer oversimplifies the Postgres side. The Iceberg side is correct. |
| Beginner clarity | 5.0 | The Postgres vs Iceberg contrast structure is excellent. Steps 1/2/3 in the "Iceberg + Parquet Solution" section make the mechanism concrete. "The Catch" section (renaming columns requires rewriting) is a useful bonus that builds accurate mental model. |
| Practical applicability | 4.75 | Correctly uses Iceberg + Parquet + MinIO + Trino framing. The schema evolution mechanism is accurately described for production use. |
| Completeness | 4.50 | Covers the main mechanism well. Missing: doesn't mention that Spark ingestion jobs also need to be updated to include the new column in their SELECT (the Postgres schema change is automatic but the Spark job that copies data needs a code change). In a real production scenario, this is the next question the engineer asks. |
| **Average** | **4.625** | |

---

## What the answer got right

1. Iceberg ADD COLUMN is metadata-only — milliseconds, no file rewrite — correct.
2. Columns tracked by name/ID, not position — correct and important.
3. Old Parquet files missing new column → Trino fills NULL — correct.
4. New files have the real column values — correct.
5. "The Catch" (renaming requires rewriting) — accurate and useful.

## What the answer missed

1. **Postgres ADD COLUMN oversimplification.** PostgreSQL 11+ can add a nullable column without a table rewrite — it's O(1). The Postgres problem with ADD COLUMN is when a non-nullable column with a dynamic default is added, or in older Postgres versions. This affects the strength of the contrast argument.

2. **Spark ingestion job update.** When a new column is added to the Iceberg schema, the Spark job reading from Postgres needs to be updated to SELECT the new column. The schema change in Iceberg doesn't automatically make the data appear — someone has to write data for the new column.

---

## Resource bug note

`resources/13-postgres-to-iceberg-ingestion.md` may have content about schema evolution. If it describes Postgres ADD COLUMN as always-slow, it should be updated to note the Postgres 11+ improvement (nullable ADD COLUMN is O(1) in modern Postgres).

---

## Topic score updates

**Column-oriented storage — what it is and why it's faster for analytics**
- Prior after Q3 this iter: avg 4.313 across 5 questions
- This answer: 4.625 (6th angle — schema evolution / why columnar enables metadata-only ADD COLUMN)
- New running avg: (21.565 + 4.625) / 6 = **4.365** across 6 questions
- Status: PASSED (improving steadily)

**What a data lakehouse is and how it differs**
- This answer exercises lakehouse-specific features (Iceberg schema evolution, ACID)
- Topic: 4.625/6 — PASSED
