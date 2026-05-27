# Iter27 Q2 Score

**Question**: Watermark-based incremental ingestion on `updated_at` — rows deleted in Postgres (hard delete, no `deleted_at`) accumulate as zombie rows in Iceberg. 50,000 zombie rows now. Detect, fix, prevent without full-refresh nightly.
**Topic**: Postgres-to-Iceberg ingestion
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 5 |
| Practical applicability | 4.75 |
| Completeness | 4.75 |
| **Average** | **4.81** |

**Feedback**: Excellent root cause explanation ("watermark only sees changes; hard DELETE leaves no trace — the row simply stops existing in Postgres"). Detection via LEFT JOIN in Trino (zombie rows missing from Postgres) is practical. Snapshot rollback as first-resort correctly presented but appropriately noted as likely too late after 8 months. DELETE + rewrite_data_files + expire_snapshots three-step sequence correct. CALL syntax uses `iceberg.system.*` (correct catalog name). Prevention options: soft delete (recommended, low friction), weekly reconciliation (safety net), CDC/Debezium (only if real-time required) — three well-differentiated tiers. Recommended path (immediate fix → reconciliation → soft delete → CDC only if needed) is the right escalation order. Beginner clarity is the strongest in the iteration. Minor: `expire_snapshots` call missing `retain_last` parameter; Python set approach for 50K zombie IDs is fine for this scale but would OOM for millions. HTML entities in code blocks.
