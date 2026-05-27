# Iter32 Q3 Score

**Question**: JSONB `properties` column — originally flattened 5 keys. New event type has different keys (`payment_method`, `amount_cents`, `currency`) — all NULL in Iceberg. How to evolve JSONB flattening?
**Topic**: Postgres-to-Iceberg ingestion
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 4.5 |
| Practical applicability | 4.75 |
| Completeness | 4.75 |
| **Average** | **4.625** |

**Feedback**: Strong answer hitting all expected key points. Root cause correctly identified (explicit key extraction; new keys silently dropped). Spark update with `get_json_object()` for both old and new keys provided. ALTER TABLE ADD COLUMN correctly described as metadata-only; old rows return NULL — "correct behavior" framing is right. Incremental vs full-refresh distinction (createOrReplace wipes DDL) is crucial and correctly made. Preflight schema-diff check and `properties_raw` catch-all both included. One material technical bug: preflight check uses `events$schema` — not a standard Iceberg metadata table in Trino (verified against trino.io connector docs). Standard approach is `DESCRIBE iceberg.analytics.events` or `SHOW COLUMNS FROM`. An engineer copy-pasting this code will hit a runtime error. HTML entities.
