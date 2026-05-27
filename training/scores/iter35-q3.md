# Iter35 Q3 Score

**Question**: Called `overwritePartitions()` with 12-row test DataFrame on a partition with 850,000 rows — now only 12 rows remain. Data loss? Recovery? Safe use pattern going forward?
**Topic**: Postgres-to-Iceberg ingestion
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Feedback**: Excellent answer validating the iter34 late-arriving events resource fix. Correctly confirms data loss, explains the partition-replacement semantics clearly. Recovery via `events$snapshots` + `rollback_to_snapshot()` with correct Spark CALL syntax and named arguments. Critical expire_snapshots caveat included. Both safe patterns present: full-partition re-read (idempotent) and MERGE INTO (recommended — row-scoped). Strong practical guidance: 7-day snapshot retention, separate test table for testing. Minor clarity gap: `$snapshots`, "atomic," and engine labels (Spark vs Trino) not explicitly noted for beginners.
