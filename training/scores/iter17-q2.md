# Score: Iteration 17, Question 2

**Date**: 2026-05-24
**Phase**: Final
**Question**: Our nightly copy job crashed at 60%, then re-ran and created duplicate rows. How do we make the job idempotent?
**Rubric topics**: Postgres-to-Iceberg ingestion; Iceberg table maintenance

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.75 | Correctly identified append() as the non-idempotent culprit. Correctly explained overwritePartitions() as the idempotent fix: replaces only the partitions present in the DataFrame, atomic per Iceberg's snapshot isolation, produces identical results on re-run. Correctly warned against createOrReplace() for incremental use (drops entire table). Rollback: correctly labeled as "run in Spark, NOT Trino" — engine-labeling fix from iter17 resource update is working. Scheduling order and CommitFailedException mention are accurate. |
| Beginner clarity | 5.0 | The three-API comparison table (append / overwritePartitions / createOrReplace with Safe-to-re-run column) is the clearest single explanation of this distinction across all iterations. "One-line fix" closing is excellent. |
| Practical applicability | 4.75 | Directly actionable: switch append() to overwritePartitions(), pass batch_date as parameter. Cleanup options (rollback vs re-run for affected day) are both practical and correct. Scheduling order advice is correct. |
| Completeness | 4.75 | Covers the fix, why it works, three API comparison, rollback option, re-run option, partition requirement, scheduling order. Minor gap: doesn't explain that the partition must be on the column used in the batch_date filter (date(occurred_at)) for overwritePartitions() to work correctly. |
| **Average** | **4.75** | |

---

## What the answer got right

1. append() = not idempotent, correctly identified as root cause.
2. overwritePartitions() = idempotent, atomic, surgical — all correct.
3. createOrReplace() anti-pattern for incremental use — correctly warned.
4. Rollback correctly labeled "run in Spark, NOT Trino" — engine-labeling fix is landing.
5. Both cleanup options (rollback + re-run with overwritePartitions) correctly described.

## Engine labeling check ✓

The rollback CALL statement is explicitly labeled "run in Spark, NOT Trino." The iter17 resource fix (prominent engine warning in resources/17-iceberg-table-maintenance.md) is producing the desired behavior.

## Topic score updates

**Postgres-to-Iceberg ingestion**
- Prior after Q1 this iter: avg 3.800 across 10 questions
- This answer: 4.75 (11th angle — idempotency via overwritePartitions)
- New running avg: (38.00 + 4.75) / 11 = **3.886** across 11 questions
- Status: PASSED (continuing to improve from 3.694 baseline)
