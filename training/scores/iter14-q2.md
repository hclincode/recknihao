# Iter 14 Q2 — Iceberg snapshot accumulation: why files pile up and safe cleanup

## Question summary
A SaaS engineer noticed MinIO storage growing despite no new data, with thousands of files in the Iceberg metadata folder. They asked what snapshot and manifest files are, why they accumulate, and how to clean them up without losing data.

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All claims verified against official docs. Snapshots as point-in-time versions and manifests as metadata listing which Parquet files belong to a snapshot are correct definitions. All four CALL procedures are correctly labeled as Spark SQL (not Trino) — this was the critical bug from Iter 11 Q3 that is now fixed. Parameter names `older_than` and `retain_last` are correct per Apache Iceberg 1.5 Spark procedures docs (snake_case confirmed). The ordering rationale (compaction → expire_snapshots → remove_orphan_files → rewrite_manifests) is correct. The 30-day older_than for expire_snapshots and 3-day for remove_orphan_files match the resource. The note that rollback_to_snapshot is Spark-only (Trino does NOT support it) is accurate per Trino 467 docs. The $snapshots view for finding snapshot IDs works in both Trino and Spark. No factual errors detected. |
| Beginner clarity | 4 | The Git-commits analogy for snapshots and the description of manifests as "metadata files listing which Parquet files belong to a snapshot" are effective entry points for a beginner. Safety rationale for older_than and rollback instructions are framed well. One point docked because jargon terms (manifest, compaction, orphan files, retain_last, ACID) appear without inline plain-English glosses in the body of the answer — a beginner following the answer will hit unfamiliar terms. The "like Git commits" metaphor helps but only partially covers the gap. |
| Practical applicability | 5 | The engineer gets a complete, runnable maintenance schedule: four CALL procedures in the correct order with correct parameter values, scheduling recommendations (nightly at 4 AM vs weekly Sunday 3 AM), Airflow/CronJob implementation guidance, per-table invocation clarification (10 tables = 10 invocations), rollback procedure with $snapshots query, and the critical Spark-vs-Trino context (submit via spark-submit, not Trino console). An engineer following this answer knows exactly what to build next. |
| Completeness | 5 | Fully addresses all three sub-questions: (1) what snapshot and manifest files are, (2) why they accumulate (every write creates new files, old files held by snapshots indefinitely without maintenance), (3) how to clean up safely (four-step procedure in order with older_than safety window, retain_last as safety net, and rollback as emergency tool). The ordering rationale (not just the order itself), the distinction between Spark and Trino syntax, and the scheduling guidance all present. No material gaps. |
| **Average** | **4.75** | |

## Topic updated

**Topic**: Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup
- Prior avg: 4.083 (3 questions: Iter 8 Q1 = 4.50, Iter 9 Q3 = 4.25, Iter 11 Q3 = 3.50)
- New score: 4.75
- New running avg: (4.50 + 4.25 + 3.50 + 4.75) / 4 = **4.25**
- Status: PASSED (avg 4.25 >= 3.5 threshold, 4 questions from distinct angles)

## Key finding

This answer represents a clean validation that the Iter 11 Q3 bug fix worked. Iter 11 Q3 scored 3.50 specifically because all maintenance SQL used `CALL iceberg.system.*` syntax without engine labels, causing engineers to paste Spark procedures into Trino and get syntax errors. The resource was subsequently updated with an explicit "Engine context: Spark vs Trino syntax" section that labels every CALL block as Spark SQL and provides the corresponding Trino ALTER TABLE EXECUTE equivalents. This answer correctly reproduces that framing — CALL procedures as Spark SQL, rollback as Spark-only — earning the full technical accuracy score.

The beginner clarity gap (jargon without inline glosses) is a persistent pattern across all maintenance answers. The resource has the glossary table at the bottom but the responder does not consistently surface it inline.

## Resource gap

No new resource gap introduced by this answer. The existing `resources/17-iceberg-table-maintenance.md` is producing correct technical output. The persistent beginner-clarity gap (inline glosses for "manifest", "compaction", "orphan", "ACID", "snapshot isolation") is a known issue flagged in Iter 8 Q1 and Iter 9 Q3 — the resource has a Key Terms table at the bottom but the responder continues to drop terms without inline glosses in the answer body. The teacher could address this by adding a "plain English" sidebar box at the top of the maintenance operations section (above the four procedures) defining the five terms before they appear in code.
