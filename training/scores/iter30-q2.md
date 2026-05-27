# Iter30 Q2 Score

**Question**: Postgres soft-delete pattern (`deleted_at` timestamp) — watermark ingestion captures soft-deletes as updates, deleted rows accumulate in Iceberg (30% of table), analysts must add `WHERE deleted_at IS NULL` manually. How to handle?
**Topic**: Postgres-to-Iceberg ingestion
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 3.0 |
| Beginner clarity | 4.0 |
| Practical applicability | 3.0 |
| Completeness | 3.0 |
| **Average** | **3.25** |

**Feedback**: Root cause correctly identified (watermark sees `updated_at` change when `deleted_at` is set; Iceberg stores the row as a regular update). Two of four expected options present: one-time DELETE+rewrite_data_files and filter at ingest. Critical gap: missing `expire_snapshots` — the answer claims "table drops to roughly 70% of current size after compaction" but `rewrite_data_files` alone does NOT free MinIO bytes; old files remain referenced by prior snapshots until `expire_snapshots` runs. Engineer following this will see no MinIO change. This is the same error as Iter 10 Q1 (GDPR erasure). Missing: Trino view for immediate analyst protection (`CREATE VIEW events_active AS SELECT * WHERE deleted_at IS NULL`), CDC/Debezium as a future-state option, and the zombie-row trap (rows soft-deleted after first ingest are excluded from subsequent incremental batches and linger forever in Iceberg). HTML entities.
