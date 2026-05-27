# Iter27 Q4 Score

**Question**: Initial bulk load of 150M row Postgres table (80 columns, ~300 GB) fails with OutOfMemoryError after 30 minutes. 8 Kubernetes workers at 4 GB each. How to tune JDBC read, Spark memory, and write strategy?
**Topic**: Postgres-to-Iceberg ingestion
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 4.75 |
| **Average** | **4.75** |

**Feedback**: Root cause correctly identified: too few JDBC partitions means each executor buffers too many rows, exhausting 4 GB heap. `SELECT MAX(id)` before the JDBC read for dynamic upperBound is the canonical fix and is present. `numPartitions = 150` starting point with escalation path (try 256-384 if still OOM) is practical. `fetchsize = 10000` correct for bulk loads (default 10 is far too low). `overwritePartitions()` explicitly preferred over `createOrReplace()` with a concrete explanation of why `createOrReplace()` is dangerous for large tables (drops everything if job fails at 80M). Executor memory headroom calculation (3.5 GB heap + 500 MB JVM overhead from 4 GB pod) is correct. `spark.sql.adaptive.enabled=true` recommendation is valid. Post-load compaction mentioned. "Library into a backpack" analogy is effective. Complete code skeleton directly actionable. Minor: the size estimate logic (1M rows × 5 KB = 5 GB per partition exceeds 4 GB executor) conflates uncompressed row size with Spark columnar in-memory representation — Parquet is read column-by-column, so actual per-partition memory is closer to 500 MB-1 GB for 1M rows at this width. The conclusion (increase numPartitions) is still correct. HTML entities in code blocks.
