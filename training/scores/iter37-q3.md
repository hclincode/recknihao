# Iter37 Q3 Score

**Question**: Postgres primary failed over, replica lagged 20-25 minutes, Iceberg watermark already advanced past the gap. How to detect what's missing and recover?
**Topic**: Postgres-to-Iceberg ingestion
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4.5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.875** |

**Feedback**: Best Postgres-to-Iceberg answer of the extended phase. All expected elements present: detection via Iceberg-vs-PRIMARY max(updated_at) comparison, backfill from PRIMARY for the exact gap window, idempotent MERGE INTO on event_id, prevention via pg_last_xact_replay_timestamp() + 15-30 min lag buffer. "Why each step matters" section reinforces critical reasoning. Verification step and primary-vs-replica tradeoff rule included. Minor clarity gaps: LAG_BUFFER, watermark, MERGE INTO appear without inline definitions; pg_last_xact_replay_timestamp() mentioned without the "returns NULL on primary; query replica connection" caveat. Validates iter34/35 detection-recipe resource additions.
