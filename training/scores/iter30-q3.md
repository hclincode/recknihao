# Iter30 Q3 Score

**Question**: `user_sessions` table (500M rows) updated on every page view, watermark Spark job pulls 20–50M rows per 15-minute run, job takes 40 minutes. What should we do?
**Topic**: Postgres-to-Iceberg ingestion
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.0 |
| Beginner clarity | 4.0 |
| Practical applicability | 4.0 |
| Completeness | 3.0 |
| **Average** | **3.75** |

**Feedback**: Diagnosis is correct (watermark designed for append-only fact tables; user_sessions is a mutable dimension). MERGE INTO syntax valid for Spark 3 + Iceberg 1.5.2. Three completeness gaps: (1) "narrow the scope" option entirely missing — ingest only closed sessions (WHERE session_end IS NOT NULL) as the cheapest first fix; (2) CDC/Debezium not mentioned despite being applicable for high-churn tables; (3) append-only event redesign not surfaced. Solution 3 uses `createOrReplace()` on a 500M-row table — same dangerous DROP+CREATE semantics flagged in Iter 7 Q2; should use `overwritePartitions()`. Solution 1 (MERGE INTO with full-table reads every 15 minutes) underplays the replica load; a source-side time filter would cut data movement. Explicit "stop the 15-min/40-min overlap now" warning is implicit but not stated. HTML entities.
