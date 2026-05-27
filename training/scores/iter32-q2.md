# Iter32 Q2 Score

**Question**: Mobile app batches events offline; events with `occurred_at` 3 days ago arrive today. Watermark already advanced. Late events missing from Iceberg. How to handle without full re-run?
**Topic**: Postgres-to-Iceberg ingestion
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.0 |
| Beginner clarity | 4.0 |
| Practical applicability | 4.0 |
| Completeness | 3.5 |
| **Average** | **3.875** |

**Feedback**: Batch-window + `overwritePartitions()` recommendation is technically valid with correct atomicity/idempotency claims. Warnings against `append()` (doubles counts) and `createOrReplace()` (table wipe) are correct. "Watermark and batch-window cannot coexist on the same table" callout is the most important architectural guardrail and was correctly surfaced. CronJob YAML and weekly catch-all replay are directly actionable. Critical completeness gap: the lightest-touch fix — switching the watermark column from `occurred_at` (event time) to `updated_at`/`ingested_at` (Postgres row insertion time) — is missing entirely. A late-arriving event inserted into Postgres today has `updated_at = now()` and would be captured on the next incremental run with no architectural change. Also missing: lag-buffer defensive pattern and one-time MERGE INTO backfill recipe for already-missed events. HTML entities.
