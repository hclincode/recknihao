# Iter 7 Q2 — Idempotent Spark ingestion and duplicate cleanup on Iceberg

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3 | Watermark pattern and dedup logic are correct. The critical error is `createOrReplace()` in Part 2: in Spark Iceberg, `createOrReplace()` is a full table replacement (semantically DROP + CREATE), not a partition-scoped overwrite. An engineer following this literally for `problem_date = '2026-05-22'` would drop the entire events table and replace it with only that one day's rows. The correct call for partition-scoped overwrite is `df.writeTo(...).overwritePartitions()`. The `DELETE FROM ... WHERE batch_loaded_at > ...` alternative is correct. Maintenance calls are correct. |
| Beginner clarity | 4 | Well-structured three-part layout. Watermark concept explained with concrete MinIO path example. Code blocks accompanied by plain-English rationale. Minor jargon ("idempotent", "atomic") used with brief explanations. One point deducted because "createOrReplace()" is presented as obviously safe when it is actually the dangerous call in this context. |
| Practical applicability | 3 | Part 1 (future prevention) is directly actionable and correct. Part 2 (cleanup) is dangerous as written — following it would silently destroy unaffected partitions. The `batch_loaded_at` DELETE alternative in Part 2 is safe and actionable, but it is positioned as secondary. An engineer who reads the answer top-to-bottom will likely use the `createOrReplace()` path first. One point deducted for each of: the primary cleanup path being wrong, and no mention of Iceberg time-travel rollback as a safer first option. |
| Completeness | 4 | Both sub-questions (prevent + cleanup) are addressed. Defensive dedup within the incremental job is present. Missing: Iceberg snapshot rollback (`CALL iceberg.system.rollback_to_snapshot`) as the safest first step when data is already doubled; JDBC parallelism knobs (`partitionColumn`, `numPartitions`) that are in the resource and affect production reliability; and the `overwritePartitions()` vs `createOrReplace()` distinction — which is exactly the conceptual gap the answer exploits incorrectly. |
| **Average** | **3.50** | |

---

## Topic updated

**Topic**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling

- Prior avg: 4.50, 1 question
- This answer score: 3.50
- New running avg: (4.50 + 3.50) / 2 = **4.00** across 2 questions
- Status: **PASSED** (avg 4.00 >= 3.5 threshold, 2 questions asked — minimum coverage met)

---

## Key finding

The answer correctly solves the future-prevention problem (watermark + dedup) but introduces a material production hazard in the cleanup path: `createOrReplace()` in Spark Iceberg replaces the entire table, not just the affected partition, which would destroy unaffected data when scoped to a single date. This error would not be caught by a beginner following the instructions.

## Resource gap

`resources/13-postgres-to-iceberg-ingestion.md` needs a dedicated "Idempotency and cleanup" section covering: (1) `overwritePartitions()` vs `createOrReplace()` — name the difference explicitly (partition-scoped vs full table); (2) Iceberg snapshot rollback (`CALL iceberg.system.rollback_to_snapshot`) as the first-resort cleanup tool before any data rewrite; (3) using `batch_loaded_at` as a DELETE filter for targeted row removal. The current resource shows dedup within the incremental job (step 3 of the skeleton) but has no cleanup recipe for the case where duplication has already occurred.
