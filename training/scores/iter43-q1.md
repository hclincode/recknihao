# Iter43 Q1 Score

**Question**: Is SHOW COLUMNS a reliable diagnostic for TIMESTAMP_MILLIS precision loss, and what is the correct check?
**Topic**: Postgres-to-Iceberg ingestion
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 3 |
| Beginner clarity | 4 |
| Practical applicability | 3 |
| Completeness | 4 |
| **Average** | **3.50** |

**Feedback**: The core diagnostic insight is correct and addresses the key gap from iter42: SHOW COLUMNS reports Iceberg's logical schema (always TIMESTAMP(6)) and cannot reveal physical Parquet precision; outputTimestampType=TIMESTAMP_MILLIS is the canonical Spark culprit; the remediation path (re-read from Postgres, overwritePartitions) is correctly framed since old microseconds cannot be recovered from Iceberg. However, the runnable check `EXTRACT(MICROSECOND FROM occurred_at) % 1000 != 0` will fail in Trino — Trino's EXTRACT does not support a MICROSECOND field (supported fields stop at SECOND; only a `millisecond()` function exists). The correct Trino-native diagnostic is `WHERE date_diff('microsecond', date_trunc('millisecond', occurred_at), occurred_at) != 0` or `WHERE format_datetime(occurred_at, 'SSSSSS') NOT LIKE '___000'`. An engineer pasting this into Trino 467 will get a parse error at the exact moment they are trying to diagnose data loss — same class of failure as the iter11 TIMESTAMPADD bug. Also missing: a quick-win sanity check (`SELECT occurred_at FROM ... LIMIT 5` to visually inspect trailing digits) and a Spark-side verification (`spark.read.parquet(path).schema` shows the physical TimestampType precision). Resource gap: `resources/13-postgres-to-iceberg-ingestion.md` needs a "Diagnosing timestamp precision loss" subsection with a Trino-valid query, not a Postgres-style EXTRACT MICROSECOND.
