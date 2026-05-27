# Iteration 46, Q2 — Score

**Question**: Six months ago we set up our events table partitioned only by `day(occurred_at)`. A few weeks ago I ran `ALTER TABLE iceberg.analytics.events SET PROPERTIES partitioning = ARRAY['day(occurred_at)', 'tenant_id']` to add tenant_id partitioning. But our dashboards that query a single tenant's data for the last 90 days are still just as slow as before — Trino is still opening thousands of files. I thought adding tenant partitioning would make per-tenant queries faster. What's going on?

**Topic**: Iceberg partition design for SaaS: strategies, small-files, compaction

---

## Technical verification (via WebSearch against iceberg.apache.org and trino.io)

1. **Does `ALTER TABLE ... SET PROPERTIES partitioning = ...` in Iceberg only apply to new writes?**
   YES — confirmed via iceberg.apache.org/docs/latest/evolution/ and multiple secondary sources: "Partition evolution is a metadata operation and does not eagerly rewrite files. The new partition specification applies to all new data written to the table while all prior data still has the previous partition specification." Iceberg stores the partition spec version with each data file in metadata; old files retain the old spec until rewritten.

2. **Will the old files prevent tenant-level pruning?**
   YES — the planner evaluates partition filters against each file's partition spec. Old-spec files have NO tenant_id partition boundary, so a tenant predicate cannot prune them — the engine must read all old-spec files in the day range and filter at scan time.

3. **Is `CALL iceberg.system.rewrite_data_files` valid Spark SQL?**
   YES — confirmed at iceberg.apache.org/docs/1.5.1/spark-procedures/. Valid options include `target-file-size-bytes`, `min-input-files`, `partial-progress.enabled`, etc.

4. **Is `CALL iceberg.system.*` available in Trino?**
   NO — confirmed via trino.io/docs/current/connector/iceberg.html. Trino's Iceberg connector exposes maintenance procedures ONLY via `ALTER TABLE ... EXECUTE <procedure>` syntax (e.g., `optimize`, `expire_snapshots`, `remove_orphan_files`, `optimize_manifests`). There is no `CALL` procedure for the Iceberg connector in Trino. The responder's explicit engine label ("Run in Spark SQL via spark-submit (NOT in Trino)") is correct and important — and matches the production-stack split (Spark for ingestion/maintenance, Trino for queries) defined in prod_info.md.

5. **Does `rewrite_data_files` rewrite old files under the current (new) partition spec?**
   YES — confirmed via Iceberg GitHub issue #7557 ("Support Rewrite Datafiles into a custom Partition Spec"): "Currently, `rewrite_data_files` always uses the current table partition spec when rewriting." This is exactly the behavior the responder leverages.

6. **Is `min-input-files => '1'` the right knob to force rewriting partitions that already have only one file?**
   YES — by default, `min-input-files=5` skips partitions with fewer than 5 input files. For partition-evolution migration, where the old partitions may already contain one large file each, `min-input-files=1` is required to force the rewriter to touch every group.

7. **Production-stack fit (prod_info.md)**:
   - Spark is the ingestion/maintenance engine (Spark + Iceberg 1.5.2) — `CALL` procedure correct.
   - Trino 467 is the query engine — explicitly told not to run the procedure there. Correct.
   - On-prem MinIO storage — 2x temporary spike caveat correct for on-prem capacity planning.

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| **Technical accuracy** | 5 | Every factual claim verified. The core mechanism (metadata-only spec change, old-spec files cannot be tenant-pruned, `rewrite_data_files` always uses current spec) is correct. Engine label is correct: Spark CALL syntax explicitly NOT available in Trino. `min-input-files=1` and `target-file-size-bytes=268435456` (256 MB) are both reasonable choices for the migration. Minor refinements possible but not corrections: (a) could mention `partial-progress.enabled=true` so a partial failure on a 6-month rewrite doesn't roll back the entire commit; (b) could mention that the old delete-files-via-snapshots will still hold references until `expire_snapshots` runs — the responder does mention this in the storage section, just doesn't tie it to the read path. |
| **Beginner clarity** | 4 | Strong pedagogical structure: states the symptom, presents the "two zones" of data with a clear table, walks the query planner's behavior step-by-step, and closes with a one-paragraph takeaway. The "old data stays slow / new data zooms" framing is memorable. One point off for unexplained jargon: "partition spec," "partition pruning," "snapshot," `expire_snapshots`, `remove_orphan_files`, "spark-submit" all appear without inline plain-English glosses. A reader who has never run `expire_snapshots` will not know it's the procedure that frees the old Parquet files from MinIO. |
| **Practical applicability** | 5 | Engineer leaves with: (1) a precise diagnosis (the spec change was metadata-only); (2) the exact runnable Spark SQL with sensible parameter values; (3) explicit engine guidance (Spark, not Trino); (4) a maintenance-window scheduling recommendation with an ingestion-conflict warning; (5) a concrete storage-spike number (~2x) and a follow-up cleanup procedure (`expire_snapshots`, `remove_orphan_files`); (6) an expected post-rewrite query profile ("~90 files instead of thousands"). This is the cleanest "what do I run Monday morning" output possible for this question. |
| **Completeness** | 5 | Hits every item on the expected-answer checklist: ALTER TABLE is metadata-only, old files can't be pruned by tenant_id, partition evolution gotcha named, fix via `rewrite_data_files`, engine label (Spark only, not Trino), one-time operation (responder writes "run **once**, not on a schedule"), ~2x storage spike, schedule during low traffic. Goes one step beyond the checklist with the "after the rewrite" expected file count and the ingestion-conflict warning, both production-relevant. |

**Average**: (5 + 4 + 5 + 5) / 4 = **4.75**

---

## Rubric update

Topic: Iceberg partition design for SaaS: strategies, small-files, compaction
- Prior: avg 4.450 across 5 questions (per rubric table line 35)
- New: (4.450 × 5 + 4.75) / 6 = (22.25 + 4.75) / 6 = 27.00 / 6 = **4.500** across 6 questions
- Status: **PASSED** (well above 3.5 threshold, 6 different angles tested)

This is the third clean angle on partition evolution / repartition mechanics (Iter 3 Q2 hidden-partitioning + maintenance, Iter 7 Q4 tenant-only partitioning skew with two factual errors, Iter 8 Q4 partition-pruning-not-firing where the answer notably MISSED the partition-evolution gotcha). This iter46 Q2 answer is the corrective answer — the gotcha that Iter 8 Q4 missed is now front and center.

---

## Notes for teacher

No new resource gaps identified for the core mechanics — the responder handled the partition evolution gotcha cleanly, named the right procedure, gave the right options, and correctly labeled the Spark-vs-Trino split.

Minor improvements worth queuing for `resources/10-lakehouse-partitioning.md`:

1. **Add a "Partition evolution gotcha" callout box** (if not already present) explicitly stating: "ALTER TABLE ... SET PROPERTIES partitioning = ... is metadata-only. Old files remain under the old spec and cannot be pruned by the new partition columns. To migrate historical data, run `CALL iceberg.system.rewrite_data_files(...)` in Spark with `min-input-files => '1'`." This callout should reference back to the symptom ("queries on old data are still slow after I added a partition column") so the responder can find it from multiple question angles.

2. **Inline glosses** for `expire_snapshots`, `remove_orphan_files`, `target-file-size-bytes`, `min-input-files`, and "partition spec" at first use in the partition-evolution subsection. The responder reproduces them faithfully but a beginner will leave with the action items unanchored to concepts.

3. **Add `partial-progress.enabled => 'true'` to the recommended options** for any rewrite that will touch more than ~30 days of historical data. Without it, a single failed group rolls back the entire 6-month rewrite — a real risk on a long-running job.

4. **Tie the read-path effect of `expire_snapshots` explicitly to the storage-spike timeline**: the answer mentions the spike and the cleanup procedure separately, but does not say that the old Parquet files remain readable (and referenceable) until snapshot expiry. An engineer who runs the rewrite and immediately verifies MinIO usage will see ~2x storage and may panic — the resource should preempt that.

Sources consulted:
- [Apache Iceberg — Evolution docs](https://iceberg.apache.org/docs/latest/evolution/)
- [Apache Iceberg — Spark Procedures (1.5.1)](https://iceberg.apache.org/docs/1.5.1/spark-procedures/)
- [Trino — Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html)
- [Apache Iceberg GitHub issue #7557 — current-spec behavior of rewrite_data_files](https://github.com/apache/iceberg/issues/7557)
- [Dremio — Future-Proof Partitioning with Apache Iceberg](https://www.dremio.com/blog/future-proof-partitioning-and-fewer-table-rewrites-with-apache-iceberg/)
