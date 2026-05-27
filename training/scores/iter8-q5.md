# Iter 8 Q5 — Iceberg vs raw Parquet folders: what the table format layer actually buys you

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All six value-adds (ACID concurrent writes, partial-write/orphan isolation, rollback, schema evolution, partition pruning, time travel) are factually correct. `CALL iceberg.system.rollback_to_snapshot`, `FOR TIMESTAMP AS OF`, and `WITH (partitioning = ARRAY[...])` are all valid Trino 467 + Iceberg 1.5.x syntax. Maintenance operations (rewrite_data_files, expire_snapshots, remove_orphan_files) are correctly named and attributed to Spark-callable system procedures. No errors found. |
| Beginner clarity | 4 | The "Without Iceberg / With Iceberg" contrast structure per section is excellent pedagogy for a zero-OLAP-background audience. "Partition pruning" is explained inline. However, "ACID transactions," "snapshot," and "orphan files" appear without one-line plain-English glosses — a beginner who hits "ACID" for the first time in item 1 may not internalize it. One point deducted. |
| Practical applicability | 5 | Runnable SQL in every section. Explicitly references the prod context (80 tenants, streaming ingest, concurrent users — all from prod_info.md). Maintenance schedule (nightly compaction, weekly snapshot expiry/orphan cleanup) matches the Iceberg 1.5.2 + Trino 467 + MinIO stack. Engineer knows exactly what to do next. |
| Completeness | 4 | Covers all five bullet points from resources/04-data-lakehouse.md "What Iceberg adds" section plus adds partial-write/orphan-file angle. Two minor gaps: (1) catalog/metastore schema discovery advantage — raw Parquet requires manual path management while Iceberg + Hive Metastore gives Spark and Trino a shared schema registry automatically; (2) Parquet column statistics / manifest-level min/max pruning (more granular than folder-level partition pruning) are not mentioned. Neither is critical for this question's scope, but a complete answer would acknowledge them. |
| **Average** | **4.50** | |

## Topic updated

**Topic**: What a data lakehouse is and how it differs from a warehouse

- Prior avg: 4.75 (1 question)
- This answer: 4.50
- New running avg: (4.75 + 4.50) / 2 = **4.625** across 2 questions
- Status: **PASSED** (avg 4.625 >= 3.5 threshold, 2 questions from different angles)

## Key finding

The answer correctly operationalizes every abstract Iceberg value-add (ACID, time travel, schema evolution, partition pruning) with runnable Trino 467 + Iceberg 1.5.x SQL and grounds the trade-off discussion in the actual production context (80-tenant on-prem MinIO stack). The "without/with" contrast structure is the clearest beginner-facing framing seen on this topic across both questions.

## Resource gap

Minor: `resources/04-data-lakehouse.md` does not mention (a) the catalog/Hive Metastore schema-discovery advantage over raw folder paths, or (b) Iceberg manifest-level Parquet column statistics (min/max per row group) as a second tier of pruning below partition pruning. Adding a one-sentence callout for each in the "What Iceberg adds" section would close these gaps for future questions on this topic.
