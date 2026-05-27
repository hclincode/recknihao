# Iter 11 Q1 — Safer Postgres-to-Iceberg loading for tables with inserts and updates

## Question summary
A SaaS engineer's nightly Spark full-overwrite job picks up both inserts and updates from Postgres but has three failure modes: crash leaves partial data, concurrent runs double row counts, and the full table must be read/written every night. They ask for a safer pattern.

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3 | Pattern B (incremental append) recommendation is correct. Watermark mechanics are correct. Dedup via row_number().over(Window.partitionBy("event_id").orderBy(updated_at.desc())) is valid Spark SQL. However, the answer contains a meaningful technical flaw: it frames the crash/concurrent-run duplicate problem as "handled by" a dedup Window function at write time, but the resource's resource explicitly recommends overwritePartitions() for idempotent re-runs — not append + dedup. append() re-runs still double-load data even after dedup runs on the incoming batch (dedup within the batch does not remove rows already appended by the first run). The answer presents dedup-before-append as the duplicate prevention strategy; it is only a within-batch dedup (not cross-run dedup). The snapshot rollback section is technically correct but presented as an emergency/afterthought rather than the primary cleanup tool the resource designates it as. |
| Beginner clarity | 4 | Watermark explained well with a plain-English analogy. The three-problem / three-fix structure is clean and easy to follow. Snapshot rollback SQL block is shown but not explained for a beginner (why is this needed? what is a snapshot?). "Row_number over Window partitionBy" is jargon-heavy and not explained. CDC/Debezium mention at the end introduces new terms without definition. Overall the narrative is clear despite these gaps. |
| Practical applicability | 3 | A SaaS engineer following this answer will implement incremental append + within-batch dedup. That is directionally right. However the engineer will still face double-count bugs on re-runs because append() + within-batch-dedup does not prevent cross-run duplicates — only overwritePartitions() or snapshot rollback does. The answer tells them to "use snapshot rollback for emergencies" but does not tell them to use overwritePartitions() as the primary idempotency strategy, which is the resource's explicit recommendation. An engineer acting on this answer will solve two of the three original problems (performance, crash recovery via watermark) but leave concurrent-run safety partially unaddressed. |
| Completeness | 3 | Covers: watermark pattern, incremental append code skeleton, CDC as upgrade path, snapshot rollback SQL. Misses: overwritePartitions() as the idempotency tool for re-runs (the resource's primary recommendation for this exact scenario); the JDBC parallelism options (partitionColumn/numPartitions) that appear in the resource skeleton; the explicit warning that append() is not naturally idempotent across runs and that overwritePartitions() is the solution. The question specifically asked about "two jobs running at the same time doubling row counts" — the correct answer per the resource is to make the job idempotent via overwritePartitions() or deterministic batch windows, not to post-hoc dedup. |
| **Average** | **3.25** | |

## Topic updated

**Topic**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling

- Prior avg: 3.75 (3 questions)
- New score this question: 3.25
- New running avg: (4.50 + 3.50 + 3.25 + 3.25) / 4 = **3.625**
- Status: PASSED (avg 3.625 >= 3.5 threshold, 4 questions asked)

## Key finding

The answer correctly recommends incremental append with a watermark but misrepresents the duplicate-prevention strategy. Within-batch dedup (row_number over event_id) removes duplicate rows within the incoming DataFrame — it does not prevent the cross-run duplicate that occurs when two jobs both append the same watermark window's rows. The resource's actual solution for concurrent-run safety is overwritePartitions() (idempotent by partition) or snapshot rollback (revert the bad append). The answer surfaces snapshot rollback only as an emergency appendix with no explanation, omitting overwritePartitions() entirely. An engineer following this answer will still get doubled row counts if two jobs run at the same time.

## Resource gap

The resource already has a strong Idempotency and cleanup section with the correct tool hierarchy (rollback first, overwritePartitions second, DELETE third). The gap is that Pattern B's code example in the resource uses append() and watermark, which is correct for crash safety but not for concurrent-run safety. The resource should add a callout immediately after the Pattern B code block stating: "append() is not safe against concurrent runs — if two jobs run at the same time and both advance the watermark, you get duplicate rows with no way to detect them at write time. For concurrent-run safety, use overwritePartitions() with a deterministic batch window (e.g., WHERE updated_at >= '2026-05-22' AND updated_at < '2026-05-23') instead of a mutable watermark." This directly addresses the engineer's original question (concurrent jobs doubling counts) and connects to the Idempotency section.
