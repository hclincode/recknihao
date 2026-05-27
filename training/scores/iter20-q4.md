# Iter20 Q4 Score

**Question**: Nightly watermark job misses hard Postgres deletes — rows disappear from Postgres but stay in Iceberg forever. How to detect and propagate?
**Topic**: Postgres-to-Iceberg ingestion
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4.5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.875** |

**Feedback**: Comprehensive and correctly prioritized. Correctly explains why watermarks miss deletes (reads current table state via JDBC, not WAL). Three options correctly ordered by complexity: soft deletes (recommended, zero architecture change), full refresh for small tables (correct createOrReplace()), CDC with Debezium (correctly labeled as advanced). MERGE INTO with spark.sql() for Spark 3 is correct. Full refresh uses createOrReplace() correctly. Soft delete implementation with trigger guidance is practical. Minor dock on clarity: CDC section introduces Debezium, Kafka, streaming, exactly-once semantics — a lot of new concepts at once, though the "don't start here" warning is correctly placed.
