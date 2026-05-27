# Iter25 Q1 Score

**Question**: Developer renamed a Postgres column from `event_type` to `event_name`. Incremental Spark job failed with schema mismatch. Fix and prevention?
**Topic**: Postgres-to-Iceberg ingestion
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 5 |
| **Average** | **4.81** |

**Feedback**: Excellent branching on incremental vs full-refresh — the key distinction that most answers miss. For incremental: ALTER TABLE RENAME COLUMN or ADD COLUMN + update Spark job. For full-refresh (createOrReplace): update Spark code only, explicitly warns "DO NOT run ALTER TABLE — it will be undone on the next run." Preflight schema-diff check using information_schema.columns is practical and production-ready. Row count validation after write closes the loop. Minor: `events$schema` metadata table syntax is non-standard in Iceberg — `DESCRIBE table` or `SHOW COLUMNS FROM table` is the correct Trino/Spark approach to get schema. HTML entity encoding in code blocks.
