# Iter 13 Q1 — Spark MERGE INTO for Postgres Users Table Upsert

## Question summary
An engineer's nightly Spark job uses createOrReplace() to load a Postgres users table into Iceberg, which overwrites all historical records. They ask for an "update if exists, insert if new" pattern that preserves history.

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4 | The core recommendation — MERGE INTO via spark.sql() on Spark 3 + Iceberg 1.5.2 — is correct and verified against official Apache Iceberg 1.5 documentation. The contrast with createOrReplace() (full table drop and rebuild) is accurate. The table-must-exist prerequisite is correctly flagged. Two inaccuracies reduce the score from 5: (1) The compaction note says to run rewrite_data_files to "merge delete files," but Iceberg's default write mode for MERGE INTO is Copy-on-Write (CoW), which rewrites affected data files directly without creating delete files. Under CoW (the default), no delete files accumulate. The framing implies Merge-on-Read behavior and will mislead engineers who look at their table's metadata. rewrite_data_files is still valid maintenance for small-file consolidation, but not for delete-file merging under the default mode. (2) "Requires updated_at column on Postgres" is stated as a hard requirement, but a full-snapshot MERGE INTO only requires the join key (user_id). updated_at is required for incremental/watermark patterns, not for full-table MERGE INTO as described in the answer. Both errors are secondary to the core pattern. |
| Beginner clarity | 4 | The answer correctly explains why createOrReplace() loses history (drops and rebuilds the entire table), which is the engineer's immediate confusion. The createOrReplaceTempView bridge step before spark.sql() is shown explicitly, which is a common stumbling block. The MERGE INTO SQL is readable and labeled with comments. One point docked: "delete files" and "compaction" appear in the final paragraph without plain-English glosses, and the distinction between full-table vs. incremental MERGE is not explained (could confuse engineers wondering when they would need updated_at). |
| Practical applicability | 4 | The code is immediately runnable on the production stack (Spark 3 + Iceberg 1.5.2 + Hive Metastore + MinIO). The createOrReplaceTempView + spark.sql("MERGE INTO ...") pattern is the correct approach for this stack and matches the resource. One point docked: the false "Requires updated_at column on Postgres" statement will cause an engineer to add a column they do not need for this pattern, and will cause confusion when they attempt a full-snapshot MERGE INTO without it and find it works fine. The CREATE TABLE IF NOT EXISTS DDL prerequisite is mentioned but the actual DDL statement is absent — an engineer setting up dim_users for the first time must look elsewhere. |
| Completeness | 4 | Answers the core question (MERGE INTO = update if exists + insert if new), explains why the current approach fails, provides working code, and adds a maintenance recommendation. One point docked: the answer does not explain that MERGE INTO operates on a full snapshot (the entire Postgres table) not just recent changes, and does not surface the Pattern 1 / Pattern 2 distinction from the resource (full-refresh createOrReplace for tiny tables, MERGE INTO for larger dimension tables). An engineer with a 500-row users table may unnecessarily implement MERGE INTO when createOrReplace would be simpler. The resource's "What NOT to use for dimension upserts" section (overwritePartitions, append) is absent. |
| **Average** | **4.00** | |

## Topic updated

**Topic**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling

- Prior avg: 3.393 (7 questions through end of Iter 12)
- Iter 13 Q2 (JDBC parallelism): 4.50 — raised running avg to approximately (3.393 × 7 + 4.50) / 8 = 28.251 / 8 = 3.531
- New score this question (Q1, 9th scored question): 4.00
- New running avg: (28.251 + 4.00) / 9 = 32.251 / 9 ≈ **3.583**
- Status: **PASSED** (≥ 3.5 threshold, 9 questions asked — well above the 2-question minimum)

## Key finding

The Iter 13 teacher fix for Bug 4 (mutable dimension table upsert pattern) is working. The weak-ai-responder now correctly recommends spark.sql("MERGE INTO ...") for Spark 3 + Iceberg 1.5.2 rather than the invalid PySpark 4.0 DataFrame chained API that appeared in the Iter 12 Q4 failure. The core pattern is technically correct and immediately runnable on the production stack. The topic has risen from 3.393 (NEEDS WORK) to approximately 3.583 (PASSED) across 9 questions.

## Resource gap

Two secondary inaccuracies remain in the answer, both traceable to content gaps in `resources/13-postgres-to-iceberg-ingestion.md`:

1. **CoW vs MoR compaction framing**: The resource's MERGE INTO section should explicitly state that Iceberg defaults to Copy-on-Write mode, which means MERGE INTO rewrites affected data files directly and does NOT create delete files. The compaction note (rewrite_data_files) should be framed as periodic small-file consolidation maintenance, not delete-file merging. A one-sentence callout ("By default, Iceberg uses Copy-on-Write for MERGE INTO — affected data files are rewritten directly, no delete files accumulate. Run rewrite_data_files weekly to consolidate small files, not because delete files are piling up.") would fix this permanently.

2. **updated_at false prerequisite**: The "Requires updated_at" note in the resource's MERGE INTO section conflates the full-snapshot pattern (where updated_at is not required) with the incremental/watermark pattern (where it is required). The section should explicitly state: "updated_at is not required for a full-snapshot MERGE INTO. It is only required if you want to do an incremental partial load (load only rows changed since the last run)."
