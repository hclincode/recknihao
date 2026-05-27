# Iter42 Q1 Score

**Question**: TIMESTAMP_MILLIS config causing composite key collisions in MERGE INTO — diagnosis and fix.
**Topic**: Postgres-to-Iceberg ingestion
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.25** |

**Feedback**: Nails the headline diagnosis (TIMESTAMP_MILLIS truncates microseconds in the Parquet file -> composite key on occurred_at collides -> MERGE classifies a new event as MATCHED and UPDATEs instead of INSERTing) with a clean before/after worked example (`14:32:17.482913` -> `14:32:17.482`) and correctly insists on re-reading from Postgres because microseconds cannot be reconstructed from Iceberg — matching the Iter 41 resource fix exactly. Technical accuracy docked one point on the `SHOW COLUMNS` diagnostic: the Iceberg *table schema* is microsecond-precision regardless of the Parquet write hint, so `SHOW COLUMNS` typically returns `timestamp(6)` even when files were written with millisecond truncation — the definitive diagnostic is inspecting actual stored values (e.g., `SELECT count(*) FROM events WHERE extract(microsecond FROM occurred_at) % 1000 != 0`) or parquet-tools file metadata, not the Iceberg column type. Completeness docked because the Postgres-side collision-detection query (`SELECT device_id, session_id, event_type, occurred_at, COUNT(*) FROM source GROUP BY 1,2,3,4 HAVING COUNT(*) > 1` — to quantify how many events were silently dropped before the fix) is absent. Practical applicability is full marks: three numbered steps, runnable snippets, and `overwritePartitions()` named correctly for the on-prem Spark + Iceberg 1.5.2 + MinIO stack.
