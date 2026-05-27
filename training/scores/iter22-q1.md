# Iter22 Q1 Score

**Question**: Postgres JSONB column with nested arrays and objects arrives as a string in Spark JDBC. Flatten at ingest or parse at query time?
**Topic**: Postgres-to-Iceberg ingestion
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.94** |

**Feedback**: Excellent. Core recommendation (flatten hot fields, keep raw blob as fallback) is correct and grounded in Parquet's lack of native JSON type. `get_json_object` for nested paths is correct. Schema evolution (old rows return NULL, no backfill required) correctly stated. MAP/STRUCT anti-pattern for analytics is correctly identified. Complete production Spark ingestion skeleton is practical. Minor: `.contains("enterprise")` on a JSON string is a substring match, not true array containment — a value like "enterprise-plus" would incorrectly match. A note about this limitation or an alternative approach would improve accuracy.
