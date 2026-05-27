# Iter37 Q4 Score

**Question**: Switched from append() to MERGE INTO. Re-ran for yesterday's window to test idempotency. Iceberg has MORE rows than Postgres. What determines MERGE INTO idempotency and what went wrong?
**Topic**: Postgres-to-Iceberg ingestion
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 3 |
| **Average** | **3.75** |

**Feedback**: Correct framework: idempotency hinges on unique join key, deterministic source read, pre-MERGE dedup. Runnable Window dedup snippet and `COUNT(*) GROUP BY HAVING > 1` diagnostic present. Gaps: (1) never explicitly prompts engineer to inspect their actual MERGE INTO ON clause — the most likely fix (change ON clause from date/updated_at to event_id) is implied but not stated directly; (2) no cleanup recipe for duplicates already in Iceberg (snapshot rollback or dedup-then-overwritePartitions); (3) Iceberg behavior of raising an error when multiple source rows match a single target row would sharpen the diagnosis. Completeness limited because the engineer can't fully act without knowing how to fix the existing duplicate rows.
