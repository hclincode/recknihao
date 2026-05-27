# Iter28 Q3 Score

**Question**: Read replica fell 8 minutes behind primary; watermark advanced past the lag window; 12,000 rows permanently missed. Detect, fix, prevent.
**Topic**: Postgres-to-Iceberg ingestion
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 5 |
| **Average** | **4.75** |

**Feedback**: Timeline diagram with primary/replica/watermark columns is the clearest visualization of this failure mode in the training run. Root cause ("a watermark is a promise; reading from a lagged replica breaks that promise") is memorable and correct. Detection by comparing row counts against PRIMARY (not replica) for the gap window is correct. Fix: backfill from PRIMARY using overwritePartitions() for idempotency is correct. Three prevention strategies (watermark buffer, pg_last_xact_replay_timestamp check, row count validation) all correct and well-differentiated. "Validation passed: source == target" closing check is the right success criterion. Complete end-to-end code skeleton is excellent. Technical accuracy docked: the lag check function (`check_replica_lag`) connects to `PG_URL` = `pg-primary:5432` — `pg_last_xact_replay_timestamp()` is a replica-only function that returns NULL on the primary; the lag check would silently fail to detect lag. The lag check should connect to `pg-replica:5432`. The surrounding explanation correctly says "query the replica" but the code has the wrong URL. Practical applicability docked slightly for the same code error. HTML entities throughout.
