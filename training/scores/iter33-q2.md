# Iter33 Q2 Score

**Question**: We switched watermark from `occurred_at` to `updated_at` to catch late-arriving events. Iceberg table is partitioned by `day(occurred_at)`. Does `overwritePartitions()` handle writes to old partitions correctly, and what else to watch out for?
**Topic**: Postgres-to-Iceberg ingestion
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 3 |
| Beginner clarity | 4 |
| Practical applicability | 3 |
| Completeness | 3 |
| **Average** | **3.25** |

**Feedback**: Correctly confirmed `updated_at` as the right watermark switch and `overwritePartitions()` as atomic/partition-scoped. Dedup ROW_NUMBER() snippet is valid. Critical gap: failed to warn that `overwritePartitions()` replaces the ENTIRE partition with DataFrame contents — if the batch pulls only 12 late-arriving rows for day=3-days-ago, it wipes thousands of existing rows. Fix is either (a) re-query all rows for affected day from Postgres, or (b) use MERGE INTO. Also missing: lag buffer (`max(updated_at) - 4 hours`), `updated_at` index check in Postgres, and explicit confirmation that `day(occurred_at)` partition spec is still correct for analyst query patterns.
