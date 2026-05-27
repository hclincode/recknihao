# Iter24 Q1 Score

**Question**: Postgres events table has UUID primary key with no timestamp column. Full reload takes 4 hours and is killing Postgres. Can we do incremental ingestion without a timestamp watermark?
**Topic**: Postgres-to-Iceberg ingestion
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 5 |
| **Average** | **4.81** |

**Feedback**: Strong answer. Correctly identifies that UUID keys cannot serve as watermarks (random distribution, no ordering guarantee). Three options in correct priority order: add `updated_at` (fastest, recommended), CDC (sub-minute freshness, higher complexity), full-snapshot MERGE INTO (temporary bridge only). `overwritePartitions()` correctly recommended over `append()` for idempotency, with concrete explanation of why `append()` risks double-loading on job failure. CALL statements labeled "Spark SQL only — does not run in Trino" consistently. `iceberg.system.*` catalog name correct. "What not to do" section is excellent (hash comparison, row numbers, UUID partitioning all correctly dismissed). Minor: local JSON watermark file approach is simplified for teaching — production systems use a state store or database; an engineer could get burned by the single-file approach at scale. HTML entity encoding (`&gt;`) appears in code blocks and would render incorrectly if copied.
