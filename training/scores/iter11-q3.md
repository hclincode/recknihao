# Iter 11 Q3 — Compaction vs ingestion scheduling conflict and concurrent query safety

## Question summary
The engineer's overnight Spark compaction job ran into a file conflict error when the morning ingestion job started while compaction was still running. They want to know how to schedule compaction and ingestion so they don't conflict, and whether analysts can safely query while compaction runs in the background.

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3 | The scheduling advice and snapshot isolation claim are correct. However, two factual errors reduce the score: (1) The conflict exception is called `OptimisticLockException` — Iceberg's actual exception is `CommitFailedException` (the optimistic concurrency model is correct, but the class name is wrong); (2) The recovery section and maintenance schedule use `CALL iceberg.system.*` syntax throughout for `rollback_to_snapshot`, `expire_snapshots`, `remove_orphan_files`, and `rewrite_manifests` — but in the production stack (Trino 467), these operations use `ALTER TABLE ... EXECUTE` syntax, not `CALL`. `CALL` syntax is Spark-specific. An engineer copy-pasting the "rollback" or maintenance SQL into Trino will get a syntax error. The compaction `CALL` in a Spark job is correct, but the answer does not label which SQL runs in which engine. |
| Beginner clarity | 4 | The framing is strong. Opens with "this is the most common operational issue," explains the conflict in plain terms before naming any exception, uses the "12-step meeting" style of "the good news is." The OptimisticLock / commit mechanism is explained in one sentence without deep jargon. Snapshot isolation is explained with a concrete "locks in which version" metaphor. Minor clarity gaps: "snapshot isolation," "manifest," and "immutable version" appear without inline plain-English definitions. The maintenance schedule mentions `rewrite_manifests` without explaining what manifests are or why they need rewriting. The "order matters" claim in the maintenance section lacks an explanation of why. |
| Practical applicability | 3 | The scheduling solution (separate ingestion and compaction by at least 2 hours) is directly actionable and matches the production stack. The safety answer for analysts is correct and reassuring. However, the recovery section is practically dangerous: the `CALL iceberg.system.rollback_to_snapshot(table => '...', snapshot_id => [...])` syntax will not work in Trino 467 — the correct syntax is `ALTER TABLE analytics.events EXECUTE rollback_to_snapshot(snapshot_id_value)`. Likewise, the weekly maintenance CALL statements will fail if run in Trino. An engineer following the recovery instructions verbatim will hit syntax errors exactly when they are most stressed (after a conflict). The answer also does not note whether the Spark `rewrite_data_files` CALL runs in Spark (correct) or Trino (wrong), leaving the engine ambiguity unresolved. |
| Completeness | 4 | The answer addresses all three sub-questions: why the conflict happened, how to schedule safely, and whether analysts can query during compaction. The full maintenance schedule is included. The recovery path (check snapshots, rollback) is present. Gaps: (1) no mention that `rollback_to_snapshot` is the first-resort recovery tool before investigating data consistency — the resource explicitly calls it the "safest cleanup tool"; (2) no guidance on whether the data is currently consistent or how to verify — the question explicitly asks "I'm not sure the data is in a consistent state"; (3) the maintenance order reasoning ("order matters" statement) is asserted without explanation; (4) the `rewrite_manifests` step lacks a plain-English rationale. |
| **Average** | **3.50** | |

## Topic updated

**Topic**: Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup

- Prior avg: 4.375 (2 questions — iter8-q1 at 4.50, iter9-q3 at 4.25)
- New score this question: 3.50
- New running avg: (4.50 + 4.25 + 3.50) / 3 = **4.083**
- Status: PASSED (avg 4.083 >= 3.5 threshold, 3 questions asked)

## Key finding

The dominant failure is engine-syntax confusion. In the production stack (Trino 467), Iceberg maintenance operations (`expire_snapshots`, `remove_orphan_files`, `optimize`, `rollback_to_snapshot`) use `ALTER TABLE ... EXECUTE` syntax, not `CALL iceberg.system.*`. The answer uses Spark `CALL` syntax for all recovery and maintenance SQL without labeling which engine runs each statement. An engineer copy-pasting the `rollback_to_snapshot` or weekly maintenance SQL into a Trino session will get a syntax error precisely when they are trying to recover from an incident. The secondary error — naming `OptimisticLockException` instead of `CommitFailedException` — is a class-name inaccuracy that will fail any engineer who searches logs or tries to catch the exception programmatically.

This error originates in the resource (`resources/17-iceberg-table-maintenance.md`), which uses `CALL iceberg.system.*` syntax throughout without clarifying that this is Spark procedure syntax. The resource was authored assuming Spark is the execution engine for all maintenance operations, but the production stack engineers will most naturally run interactive recovery SQL in Trino — where the syntax is different.

## Resource gap

`resources/17-iceberg-table-maintenance.md` needs two targeted fixes:

1. **Engine labels on all SQL blocks**: Add a comment at the top of every SQL block indicating whether it runs in Spark (`-- Run in Spark (e.g., via your Kubernetes CronJob)`) or Trino (`-- Run in Trino (interactive / dbt)`). The `CALL iceberg.system.rewrite_data_files/expire_snapshots/remove_orphan_files/rewrite_manifests` procedures are Spark-only. The Trino equivalents are: `ALTER TABLE ... EXECUTE optimize`, `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '30d')`, `ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold => '3d')`, `ALTER TABLE ... EXECUTE optimize_manifests`, and `ALTER TABLE ... EXECUTE rollback_to_snapshot(snapshot_id)`.

2. **Fix the exception name**: Replace `OptimisticLockException` with `CommitFailedException` (the actual class thrown by Iceberg's optimistic concurrency control). Add a parenthetical: "Iceberg's `CommitFailedException` (its optimistic concurrency control mechanism — each writer assumes no conflict, then checks at commit time)."
