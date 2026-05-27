# Iter28 Q2 Score

**Question**: DBA added 3 new columns to Postgres events table 2 weeks ago. Incremental Spark job still has old schema in Iceberg. How to safely add columns and what happens to historical rows?
**Topic**: Postgres-to-Iceberg ingestion
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 4.75 |
| Completeness | 4.75 |
| **Average** | **4.875** |

**Feedback**: Excellent answer. Incremental vs full-refresh distinction is the correct first diagnostic step and correctly drives different remediation paths. ALTER TABLE ADD COLUMN as metadata-only (instant, non-destructive) correctly stated. Historical rows returning NULL for new columns is correctly framed as "correct behavior, not an error." Critical warning about createOrReplace() obliterating ALTER TABLE changes is well-placed and explicit. Validation query in Trino (checking recent rows vs old rows for new column values) is practical. Backfill path via overwritePartitions() for historical enrichment correctly presented as optional. Resource reference to ingestion resource with correct section name. Technical and beginner clarity are both flawless this question. Practical applicability docked slightly: validation query uses GROUP BY on all 3 new columns which produces many rows — DESCRIBE TABLE or `SELECT COUNT(*) WHERE device_type IS NOT NULL` would be cleaner for schema verification. Completeness docked: DESCRIBE TABLE as the first verification step is missing. HTML entities in code blocks (persistent).
