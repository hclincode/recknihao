# Iter40 Q2 Score

**Question**: Where does microsecond-to-millisecond timestamp truncation happen in a Postgres -> Spark -> Iceberg -> Trino pipeline, and does it matter for analytics?
**Topic**: Postgres-to-Iceberg ingestion
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 2 |
| Beginner clarity | 4 |
| Practical applicability | 3 |
| Completeness | 3 |
| **Average** | **3.00** |

**Feedback**: The MERGE-INTO silent-data-loss scenario, the diagnostic GROUP BY query, and the BIGSERIAL / event_hash fallbacks are well-framed and genuinely useful. However, the answer's central technical claim is wrong and presented with high confidence: it says Parquet's TIMESTAMP type only stores milliseconds and that Spark "silently truncates" microseconds at the Parquet write layer. Per the Iceberg spec (iceberg.apache.org/spec/) and the Parquet spec, Iceberg requires microsecond precision and maps to Parquet's TIMESTAMP_MICROS logical type — microseconds are preserved end-to-end by default on the production stack (Spark + Iceberg 1.5.2 + Parquet + Trino 467, where the Iceberg connector exposes timestamps as TIMESTAMP(6)). The actual root cause for the user's observed loss is almost certainly either (a) an explicit `spark.sql.parquet.outputTimestampType=TIMESTAMP_MILLIS` config, (b) a cast to TIMESTAMP(3) somewhere, or (c) a display-layer truncation in a client tool — none of which the answer surfaces. The bonus expected fix (set `outputTimestampType=TIMESTAMP_MICROS` or just leave it at the default) is completely absent. Beginner clarity is fine and the MERGE failure mode is a real risk worth knowing about, but an engineer who acts on the diagnosis ("it's the Parquet layer, it's unavoidable") will skip the actual one-line fix and instead build event_hash plumbing they do not need.
