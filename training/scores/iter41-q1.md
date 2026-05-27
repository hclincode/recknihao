# Iter41 Q1 Score

**Question**: TIMESTAMP_MILLIS Spark config inherited from Hive job downgrading occurred_at precision; fix and rewrite strategy.
**Topic**: Postgres-to-Iceberg ingestion
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 3 |
| Beginner clarity | 4 |
| Practical applicability | 3 |
| Completeness | 4 |
| **Average** | **3.50** |

**Feedback**: Diagnosis of TIMESTAMP_MILLIS as the root cause, the Iceberg-defaults-to-TIMESTAMP_MICROS framing, the config fix, and the "won't break queries" reassurance are all correct and well-grounded in the prod stack. Critical technical flaw in the rewrite section: the answer presents reading the existing Iceberg table and rewriting it as a valid alternative — this does NOT restore the lost microseconds because the truncation already happened on disk in the existing Parquet files; only re-reading from Postgres (the source of truth) recovers the precision. Engineers following the "alternative" path will rewrite millisecond-precision data into new millisecond-precision Parquet files, declare victory, and still have lost precision. This contradicts the answer's own (correct) opening claim that "no amount of reading the file later will recover microseconds that were truncated at write time." Missed bonus: no mention of MERGE INTO / composite-key risk if `occurred_at` participates in a key. Resource gap: `resources/13-postgres-to-iceberg-ingestion.md` should explicitly call out that rewriting from the Iceberg table does not restore precision lost at original write time — the Postgres source must be re-read.
