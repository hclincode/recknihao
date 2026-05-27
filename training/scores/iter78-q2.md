# Iter 78 Q2 — Judge Score
**Topic**: Multi-tenant analytics (GDPR purge)
**Score date**: 2026-05-25

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 5 |
| Practical applicability | 4 |
| Completeness | 4.5 |
| **Average** | **4.375** |

## Points covered
- Correctly explains that `DELETE` alone is insufficient — creates delete files (marker) and a new snapshot, leaving Parquet files physically intact on MinIO. (Point 1 covered.)
- Explicitly explains old snapshots still reference original data files and protect them from garbage collection. (Point 2 covered.)
- `rewrite_data_files` correctly described as physically rewriting Parquet without the deleted rows. (Point 3 covered.)
- `expire_snapshots` with `retain_last => 1` correctly removes old snapshots and notes the time-travel loss trade-off. (Point 4 covered.)
- `remove_orphan_files` correctly described as the step that physically deletes unreferenced files from MinIO — "this is when data is truly gone". (Point 5 covered.)
- Verification queries provided: `SELECT COUNT(*)` and `events$snapshots` metadata table query. (Point 7 covered.)
- Mentions backups/replicas as a separate concern — good GDPR nuance.
- Notes the "run during low-traffic windows" maintenance consideration.
- Summary table at the end is highly useful for an engineer.

## Issues
1. **CALL syntax is Spark-only, but the maintenance operations are NOT Spark-only in Trino.** The answer says "Steps 2–4 are Spark-only" which conflates the CALL syntax with the underlying capability. Trino 467 (the production stack) supports all three operations via different syntax:
   - `ALTER TABLE x EXECUTE optimize` (Trino equivalent of `rewrite_data_files`, with optional `WHERE` clause)
   - `ALTER TABLE x EXECUTE expire_snapshots(retention_threshold => '7d')`
   - `ALTER TABLE x EXECUTE remove_orphan_files(retention_threshold => '7d')`

   This is a significant practical gap because the production stack runs Trino. An engineer reading this answer might spin up a Spark job when they could run everything from Trino. The answer should say the `CALL` syntax is Spark-only and mention the Trino `ALTER TABLE EXECUTE` alternatives.

2. **`older_than => current_timestamp` may fail in Trino's equivalent** because of `iceberg.expire-snapshots.min-retention` (default 7 days). Even in Spark, immediately expiring all snapshots can leave concurrent readers in a bad state. A brief note that the retention threshold may need adjustment would be useful.

3. **Merge-on-read vs copy-on-write context is missing.** The answer mentions delete files as if MoR is the only mode. A brief mention that `write.delete.mode` defaults differ by Iceberg version (1.5.2 has CoW default for V2 tables in many configs) would be more precise — though the user-visible end result (Parquet files retained until rewrite) is the same.

## Accuracy verification (via WebSearch on iceberg.apache.org / trino.io)
- Verified: `CALL iceberg.system.rewrite_data_files(where => '...')` is valid Spark syntax. WHERE clause is supported but limited to simple predicates (no function calls like `year(...)`).
- Verified: `expire_snapshots` with `retain_last` parameter is valid in Spark.
- Verified: `remove_orphan_files` physically deletes files from storage.
- Partially verified: CALL procedures with `iceberg.system.*` namespace are Spark-only. Trino exposes the same functionality via `ALTER TABLE EXECUTE` — the answer's "Spark-only" framing is too broad.
- Verified: Iceberg DELETE in MoR mode creates positional/equality delete files; underlying Parquet files are preserved until compaction.

## Resource fix needed?
**Yes — minor.** Update `resources/05-multi-tenant-analytics.md` (or wherever the GDPR purge sequence lives) to:
1. Explicitly distinguish "CALL syntax is Spark-only" from "the operation is Spark-only" and provide the Trino `ALTER TABLE EXECUTE` equivalents for `optimize`, `expire_snapshots`, and `remove_orphan_files`.
2. Briefly note Trino's `iceberg.expire-snapshots.min-retention` and `iceberg.remove-orphan-files.min-retention` catalog properties (default 7d) that govern allowed retention values.
3. Optional: brief mention of merge-on-read vs copy-on-write modes and how they affect what `rewrite_data_files` actually does.

## Updated topic average: 4.418 / 75 questions
Prior: 4.414 × 74 = 326.636
New: (326.636 + 4.375) / 75 = 331.011 / 75 = **4.413** across 75 questions. Status: PASSED.
