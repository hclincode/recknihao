# Iter29 Q2 Score

**Question**: DBA renamed Postgres column `user_email` to `customer_email`. Spark job runs without errors but new rows have NULL customer_email. What happened and how to detect schema drift?
**Topic**: Postgres-to-Iceberg ingestion
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.88 |
| Completeness | 4.88 |
| **Average** | **4.815** |

**Feedback**: Root cause correctly identified — JDBC returns NULL for columns referenced by name that no longer exist in Postgres; Spark does not throw an error, causing silent data loss. Preflight schema-diff approach (comparing information_schema.columns against Iceberg column list) is the correct detection strategy. `ALTER TABLE ... RENAME COLUMN` is accurate for Iceberg 1.5.2 (columns tracked by ID not name). `overwritePartitions()` for backfill is correct and idempotent. DBA notification protocol is a practical process recommendation. Minor: `information_schema` + `$schema` metadata table approach — `$schema` is non-standard; `DESCRIBE TABLE` or `SHOW COLUMNS FROM` is the standard Trino/Iceberg way to query column metadata. Practical applicability and completeness are strong — the fix sequence (rename column, update Spark job, backfill) is complete and ordered correctly. HTML entities in code blocks.
