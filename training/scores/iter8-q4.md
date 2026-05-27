# Iter 8 Q4 — Iceberg partition pruning not skipping rows (WHERE event_date >= '2024-01-01')

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4 | All core claims are correct: partition pruning operates at file level not row level, CALL syntax for rewrite_data_files and rewrite_manifests is valid for Iceberg 1.5.2 + Trino 467, three-layer optimization formula is accurate. One issue: answer opens by asserting "hidden partitioning is working correctly" as a statement rather than a hypothesis — the EXPLAIN evidence hasn't been shown yet, so this is premature. The "outdated manifest metadata" cause is valid. No factually wrong claims. |
| Beginner clarity | 3 | The file-vs-row distinction and the "100 files, 80 skipped, 20 remain" example are clear. However, "manifest metadata," "row-group statistics," "partition spec," "partition predicate mismatch," and "hidden partitioning" all appear without plain-English inline glosses. "Compaction" is used in the CALL statement without explaining what it does. The opening "hidden partitioning" sentence may confuse an engineer who doesn't know if they set up hidden partitioning or not. |
| Practical applicability | 4 | Highly actionable: EXPLAIN ANALYZE command given, file count interpretation rule given, two runnable CALL statements with correct parameters, WHERE clause type-mismatch diagnostic included. Minor gap: answer does not warn that EXPLAIN ANALYZE actually executes the query (unlike EXPLAIN), which is important for a large table. Also does not specify that rewrite_data_files can be run through Trino's Iceberg connector directly (vs needing Spark). |
| Completeness | 3 | Covers the file-vs-row misconception and three common pruning failure causes. Critical omission: for an engineer who "added a date partition" to an existing table, the most likely root cause is that Iceberg's partition spec change does NOT repartition existing data files — old files remain unpartitioned and cannot be pruned by the new spec. This gotcha is absent from the answer entirely and is almost certainly why the engineer's queries are still slow. The answer's three causes (small-files, outdated manifests, predicate mismatch) are all valid but secondary compared to the existing-data-not-repartitioned issue. |

**Average: 3.5**

## Topic updated

- **Topic**: Query performance basics: partitioning, indexing strategy for analytics
- **Prior avg / count**: 5.0 / 1 question
- **New running avg**: (5.0 + 3.5) / 2 = **4.25** across 2 questions
- **Status**: PASSED (avg 4.25 >= 3.5 threshold, 2 questions asked — minimum coverage met)

## Key finding

The answer explains the file-vs-row pruning distinction well but misses the single most production-relevant gotcha: adding a partition spec to an existing Iceberg table does not repartition existing data files, so all pre-existing data remains unpartitioned and cannot be skipped. For an engineer who says they "added" a partition to a running table, this is the dominant cause of the symptom they described, yet it appears nowhere in the answer.

## Resource gap

`resources/10-lakehouse-partitioning.md` needs a "Partitioning existing tables" warning section explaining that `ALTER TABLE ... SET PROPERTIES partitioning = ...` applies only to newly written files going forward — existing files are unaffected and will be fully scanned. The fix is to run `rewrite_data_files` after the schema change to rewrite old files into the new partition layout. This should be called out as the most likely root cause when an engineer reports that a newly added partition is not pruning.
