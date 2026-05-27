# Iter23 Q1 Score

**Question**: Postgres schema change (new NOT NULL column) broke Iceberg ingestion mid-day — query fails, null values appearing in Iceberg. How do you diagnose and fix?
**Topic**: Postgres-to-Iceberg ingestion
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 4.75 |
| Completeness | 5 |
| **Average** | **4.94** |

**Feedback**: Excellent. Correctly identifies the root cause (NOT NULL column added without default visible to SELECT *, nullable mismatch between Postgres and Iceberg schemas). Schema evolution path via `ALTER TABLE ADD COLUMN` is metadata-only in Iceberg — correctly identified. Defensive column alignment pattern (explicit column list in SELECT rather than SELECT *) is the right prevention. Minor: could have mentioned adding an alert or schema hash comparison step to detect upstream schema changes proactively before they cause failures.
