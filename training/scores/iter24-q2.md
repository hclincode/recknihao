# Iter24 Q2 Score

**Question**: Enterprise tenant reports stale data (2 days old). Spark job logs all show SUCCESS. Systematic investigation process?
**Topic**: Multi-tenant analytics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 5 |
| **Average** | **4.75** |

**Feedback**: Excellent 7-phase investigation structure with concrete timing estimates per phase. Phase 1 (query Iceberg directly for MAX(ingested_at)) is the right first diagnostic. Phase 3 (watermark check with MinIO inspection) is practical and correctly identifies the "zero new rows + SUCCESS" failure mode as the most common root cause. Phase 4 ($snapshots check) correctly uses Trino syntax. Phase 6 (Trino metadata cache) is correctly noted as possible but uncommon. CALL labeled Spark-only correctly. Minor issues: (1) "Rows read from Postgres: 0" log pattern is invented — not standard Spark output; actual Spark logging is less structured; (2) HTML entity encoding (`&amp;gt;`) in code blocks; (3) assumes watermark-based incremental ingestion (correct for most setups, but not for full-refresh tables which have no watermark).
