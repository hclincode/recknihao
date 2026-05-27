# Iter39 Q3 Score

**Question**: No single unique event_id — events identified by (device_id, session_id, event_type, occurred_at). How to write MERGE INTO ON clause for composite key? Does idempotency hold?
**Topic**: Postgres-to-Iceberg ingestion
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 3 |
| **Average** | **3.75** |

**Feedback**: ON clause with 4-column AND join is correct. Idempotency reasoning correct. Pre-MERGE COUNT(*) GROUP BY diagnostic present. Critical gap: occurred_at precision drift not mentioned — Postgres microsecond vs Parquet/Iceberg millisecond truncation can make distinct events look identical on the composite key, causing silent data loss (matched and updated when they should be separate rows). This is the most common production failure mode for occurred_at in composite keys. Also missing: no fallback suggested (hash surrogate, sequence column) for when diagnostic returns duplicates.
