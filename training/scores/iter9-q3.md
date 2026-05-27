# Iter 9 Q3 — Iceberg snapshot accumulation: why files pile up and how to clean them safely

## Question summary

MinIO storage growing despite no new data. Thousands of files in the Iceberg metadata folder. Engineer asks what snapshot files are, why they accumulate, and how to clean up without losing data.

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3 | Core maintenance model is correct: four procedures, correct ordering rationale, correct scheduling cadence, correct safety guarantee that remove_orphan_files cannot delete files referenced by any live snapshot. Two issues: (1) `TIMESTAMPADD(DAY, -30, CURRENT_TIMESTAMP)` is not valid Trino SQL — Trino uses `date_add('day', -30, current_timestamp)` or interval arithmetic (`current_timestamp - interval '30' day`); the answer faithfully reproduces a syntax error present in the resource that would cause all three CALL statements to fail at runtime. (2) "288 new snapshots per partition per day" conflates the streaming micro-batch file-count (288 files/day/partition for 5-min pipelines per the resource) with snapshot count — each micro-batch creates one new table snapshot regardless of how many partitions it writes to, so "288 snapshots per day" could be correct for the streaming case but "per partition" is wrong. The ordering rationale is stated correctly ("race with in-flight writes"), consistent with the resource's corrected framing. The "data hostage" framing is technically imprecise — old files cannot be deleted while any live snapshot references them, but framing this as snapshots "holding files hostage" correctly captures the user-visible effect. |
| Beginner clarity | 5 | Exceptional clarity for a zero-OLAP-background reader. Opens with a concrete "what is a snapshot" before any procedure names. The "3x storage, 10+ seconds just opening metadata" pair of concrete numbers grounds the abstract problem immediately. The 288-snapshots-per-day streaming math is vivid even if "per partition" is imprecise. The four-procedure walkthrough uses plain English for each step before the SQL appears. "Files stay on MinIO even after you think you've deleted them" is an excellent entry-level hook. The safety guarantees section answers the exact fear a beginner has ("will I lose data?"). No unexplained jargon. |
| Practical applicability | 4 | The four CALL statements are directly copy-pasteable and cover the full maintenance cycle the engineer needs. The schedule ("nightly after ingestion" / "weekly") is actionable. The ordering caveat is explicitly flagged. One deduction: the SQL is non-functional as written — `TIMESTAMPADD` will produce a runtime error in Trino 467 on the production stack. An engineer who copies this verbatim will get a syntax error and may lose confidence in the entire answer. The rollback reference is correct and useful. Emergency rollback is mentioned but no runnable CALL statement is shown for it (minor omission vs Iter 8 Q1 which also omitted it). |
| Completeness | 5 | Fully addresses all three sub-questions: (1) what are snapshot files — answered with immutable-file model and operation-by-operation breakdown; (2) why they keep accumulating — answered with the "never deletes by default" mechanism, streaming math, and "data hostage" framing; (3) how to clean up safely — answered with all four procedures, correct order, safety guarantee, and rollback mention. The resource's key insight (ordering rationale is about in-flight write race, not "snapshot-still-references" confusion) is present. No material sub-questions left unanswered. |
| **Average** | **4.25** | |

## Topic updated

**Topic**: Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup

- Prior avg: 4.50 (1 question — Iter 8 Q1, inherited unmaintained setup angle)
- New score this question: 4.25 (2nd angle — storage growth / snapshot accumulation angle)
- New running avg: (4.50 + 4.25) / 2 = **4.375** across 2 questions
- Status: **PASSED** (avg 4.375 >= 3.5 threshold, 2 questions from different angles)

## Key finding

The answer is beginner-friendly and operationally complete, but all three CALL statements contain `TIMESTAMPADD(DAY, ...)` which is not valid Trino SQL — Trino requires `date_add('day', -N, current_timestamp)` or interval arithmetic. This is a pre-existing bug in `resources/17-iceberg-table-maintenance.md` that the responder faithfully reproduced, and it would cause every maintenance statement to fail at runtime on the production Trino 467 cluster.

## Resource gap

`resources/17-iceberg-table-maintenance.md` must replace all `TIMESTAMPADD(DAY, -N, CURRENT_TIMESTAMP)` occurrences with valid Trino syntax: `current_timestamp - interval '30' day` (for expire_snapshots) and `current_timestamp - interval '3' day` (for remove_orphan_files). This same fix is needed in the inline examples (lines 79, 101) and the Quick-start schedule block (lines 203, 210). Until this is corrected, any engineer who copies the maintenance SQL will hit a runtime error on their first attempt.
