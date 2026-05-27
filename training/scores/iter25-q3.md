# Iter25 Q3 Score

**Question**: Denormalize at ingest time — join events with users in Spark to embed plan_type and company_size on each event row. Safe implementation and failure modes?
**Topic**: Postgres-to-Iceberg ingestion
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 5 |
| **Average** | **4.81** |

**Feedback**: Comprehensive and well-organized. LEFT JOIN (not INNER) to preserve events with missing users correctly identified as critical. Broadcast join for small users table correct. Six failure modes with concrete fixes, especially stale dimension values (capture plan_type at event time in Postgres; SCD Type 2 join for historical accuracy) — this is the most important failure mode and was correctly surfaced first. `overwritePartitions()` with deterministic batch_date parameter for idempotency correct. CALL statements labeled Spark-only. Post-ingest validation queries are practical and directly actionable. Minor: HTML entities throughout code blocks; `date_add()` syntax is Spark-flavored (Trino uses a different syntax) but since validation queries run in Spark context this is acceptable.
