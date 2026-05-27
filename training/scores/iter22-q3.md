# Iter22 Q3 Score

**Question**: Designing compaction, snapshot expiry, and orphan file cleanup schedule from scratch for 3 tables: high-volume events (5M rows/day, micro-batch), medium-volume users (nightly full-refresh), low-volume subscription_changes (2K/day).
**Topic**: Iceberg table maintenance
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.94** |

**Feedback**: Excellent. "144 writes/day = 288+ files/partition before compaction" math makes the urgency concrete for beginners. Table-specific schedules correctly differentiated (nightly compaction for events, weekly for users, monthly for subscription_changes). Correct operation order (rewrite → expire → orphan → manifests). CALL statements correctly labeled as Spark SQL only. K8s CronJob and Python spark-submit skeleton are directly usable. Parameter rationale (why 256 MB vs 128 MB, why min-input-files 5 vs 2) strengthens understanding. Emergency rollback included. Minor: `iceberg.analytics."events$snapshots"` in the rollback SELECT looks like Trino metadata table syntax; the SELECT could run in either engine but this isn't labeled explicitly.
