# Score: Iteration 19, Question 2

**Date**: 2026-05-24
**Phase**: Final (final iteration)
**Question**: We've been doing full-refresh on our 300M row events table (3 hours/night). Want to switch to incremental. What do we have to do? Risk of gaps or double-counts? How do we validate?
**Rubric topics**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.75 | Shadow table approach is architecturally correct and the safest possible way to switch patterns on a live production table. Backfill via `overwritePartitions()` is correct. Watermark stored in MinIO JSON file is correct. Flip via Iceberg table rename is correct (metadata-only, no data movement). `CALL iceberg.system.rollback_to_snapshot()` correctly uses `iceberg.system.*` catalog name. `CALL iceberg.system.rewrite_data_files()` in maintenance section also uses correct catalog name. Idempotency analysis (append is not idempotent; overwritePartitions is) is correct and well-explained. |
| Beginner clarity | 4.50 | Six-step procedure is comprehensive but somewhat dense for a beginner. The numbered steps are clear. The shadow table metaphor works. Explanation of the duplicate scenario (crash before watermark write) is concrete. The gap and duplicate risks are named upfront — good framing. Slight clarity cost: multiple code examples back-to-back with Spark API can feel overwhelming. "Flip" section is the most complex part and could use simpler prose. |
| Practical applicability | 4.75 | The 48-hour parallel validation window is a real operational pattern. Rename instead of copy is correctly identified as the right flip mechanism. Row count validation SQL is correct and directly runnable. `EXPLAIN` check for file scan count is actionable. The idempotent `overwritePartitions()` pattern with a fixed date is the exact production-safe approach from the resources. Post-flip maintenance schedule (4 AM compaction, weekly expire_snapshots) is correct and uses correct catalog names. |
| Completeness | 4.75 | All three sub-questions answered: (1) what to do — comprehensive 6-step procedure; (2) risk of gaps/duplicates — correctly identified and the shadow table approach mitigates both; (3) validation — row counts, aggregate comparison, duplicate event_id check, watermark verification. The rollback procedure via snapshot is explicitly documented. Minor gap: doesn't mention the 7-day default snapshot retention window (i.e., rollback is available for 7 days after the flip if default retention is in place). |
| **Average** | **4.69** | |

---

## What the answer got right

1. Shadow table + parallel validation before flip — the safest possible switchover procedure.
2. Backfill uses `overwritePartitions()` — correct and idempotent.
3. Watermark set from max `updated_at` in shadow table after backfill — correct.
4. Flip via table rename — metadata-only, milliseconds, zero data movement.
5. Rollback via `CALL iceberg.system.rollback_to_snapshot()` — correct catalog name.
6. `overwritePartitions()` + fixed date as the permanent production pattern — correctly identified.
7. Post-flip maintenance (`rewrite_data_files`, `expire_snapshots`, `remove_orphan_files`) with correct `iceberg.system.*` catalog names.

## What the answer missed

1. Doesn't mention the 7-day default snapshot retention window limits the rollback window.
2. Backfill from production Iceberg table (not from Postgres) is noted but the code does `overwritePartitions()` from the Iceberg source — technically correct but could mention that they could also backfill directly from Postgres if Iceberg is unavailable.

## Topic score updates

**Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling**
- Prior after Q1 this iter: 4.108 across 15 questions
- This answer: 4.69 (16th angle — production switchover from full-refresh to incremental)
- Running avg: (4.108 × 15 + 4.69) / 16 = (61.62 + 4.69) / 16 = **4.144** across 16 questions
- Status: PASSED (solidly above 4.0)
