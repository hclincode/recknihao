# Iter119 Q1 — Judge Report
**Topic**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling (Debezium schema evolution: NOT NULL ADD COLUMN)

## Scores
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 2 | The central premise is wrong: in modern Postgres (11+), `ALTER TABLE ... ADD COLUMN <col> NOT NULL` **with no default** on a populated table does NOT trigger a table rewrite — it errors out with "column contains null values" because there is no way to populate existing rows. There is no "rewrite path" for this DDL. The only ADD COLUMN cases that rewrite are with a *volatile* default; non-volatile defaults are metadata-only in PG 11+. The answer invented an exclusive-lock-during-rewrite story that almost never matches reality for this DDL. Secondary claim that the rewrite "stalls the replication slot" is also incorrect — even when a rewrite DOES happen, the WAL is still emitted; logical decoding doesn't freeze. The Debezium relation-message description (read from WAL via pgoutput on next change) is correct. The MERGE INTO "silent column drop" claim is half-correct: Iceberg-Spark behavior depends on `write.spark.accept-any-schema` and `mergeSchema`; many real consumers throw an AnalysisException ("Unable to find the column of the target table from the INSERT columns") instead of silently dropping. The pause-ALTER-resume sequence is conceptually right but is being applied to a scenario (NOT NULL no default) that cannot actually have produced the symptoms described. |
| Beginner clarity | 4 | Plain language, clear step structure, good narrative flow, jargon explained inline. Code blocks are concrete. Lost a point because the wrong root-cause framing will leave a beginner with a false mental model. |
| Practical applicability | 3 | The pause-ALTER-resume workflow, kubectl examples, ALTER TABLE ADD COLUMN on Iceberg, and backfill MERGE INTO are executable and roughly right for the on-prem stack (Trino 467 / Iceberg 1.5.2 / Spark / MinIO / Debezium 2.x). Engineer can act. But the diagnosis ("Postgres rewrote the table; that's why it broke") is wrong, so the prevention advice ("coordinate before table rewrites") misdirects: the real defensive action is (a) reject `ADD COLUMN NOT NULL` without default at code review (it will fail in Postgres anyway), and (b) detect schema drift on tables that ARE successfully changed (NOT NULL DEFAULT, type widen, etc.). The pause-ALTER-resume is the right pattern for the broader schema-change family, but the answer is sold under a false pretext. |
| Completeness | 3 | Covers what happens at the Debezium level (relation message via WAL/pgoutput — correct), and gives a coordination procedure. Misses: (1) that the user's stated DDL would have errored in Postgres, not silently succeeded; the team likely ran something else (`NOT NULL DEFAULT <const>` which is metadata-only in PG 11+, or `ADD COLUMN` then a `SET NOT NULL` after a backfill, or the column was added on an empty table); (2) preflight check at code review (block NOT NULL no-default DDL); (3) `write.spark.accept-any-schema=true` + writer `mergeSchema` option to let Iceberg auto-evolve; (4) Debezium's `schema.refresh.mode` and how `columns_diff` keeps in-memory schema synced; (5) for Trino 467, ADD COLUMN syntax/types and Hive Metastore behavior on Iceberg (e.g., nullable by default; can't ADD COLUMN NOT NULL in Iceberg without `iceberg.allow-null=false` semantics — Iceberg requires new columns be nullable unless using initial value default in spec v2). |
| **Average** | **3.0** | **FAIL** (below 3.5 pass threshold) |

## Verdict
**FAIL.** The answer is fluent, well-structured, and the remediation playbook is roughly correct, but it is anchored to a factually wrong premise about Postgres ADD COLUMN NOT NULL semantics. A SaaS engineer who reads this will internalize an incorrect model of what Postgres does and what triggered the outage. The teacher must correct the root-cause framing before this is acceptable for a topic that already has 50+ scored questions on it.

## What was verified correct (via WebSearch)
- Debezium PG connector uses pgoutput to read logical replication and decodes RELATION messages from the WAL to learn schema (PgOutputMessageDecoder). Debezium PG does not require a separate schema history topic (unlike MySQL connector). [debezium.io docs]
- Schema is refreshed via `schema.refresh.mode = columns_diff` by default — keeps in-memory schema in sync with the table.
- ADD COLUMN with a constant (non-volatile) default in PG 11+ is metadata-only (no rewrite). Volatile defaults (e.g., `clock_timestamp()`, `gen_random_uuid()`) DO rewrite.
- ALTER TABLE acquires AccessExclusiveLock for the duration of the operation.
- ALTER TABLE on Iceberg via Trino/Spark is metadata-only and effectively instant — that claim in Step 2 is correct.
- For MERGE INTO with Iceberg-Spark, schema-mismatch behavior depends on `write.spark.accept-any-schema=true` and writer `mergeSchema=true`; without these, MERGE INTO with a column mismatch typically raises an AnalysisException rather than silently dropping.

## Errors or gaps found
1. **WRONG: "NOT NULL no default causes a table rewrite."** PG errors out instead — there is no way to populate existing rows. If the user's table was empty or new, the DDL completes instantly; if populated, it fails. The "Postgres rewrote the table" story is fabricated for this DDL.
2. **WRONG: "Logical replication slot stalled during the rewrite."** Even on DDL operations that DO rewrite, WAL continues to flow and pgoutput continues to decode. The AccessExclusiveLock blocks application reads/writes, not the WAL sender.
3. **OVERSTATED: "MERGE INTO silently drops the new column."** This is true only with `write.spark.accept-any-schema=true` (or equivalent). In a default-configured Iceberg-Spark MERGE INTO, a column mismatch is more likely to throw an AnalysisException. The answer should state the precondition.
4. **MISSED: code-review preflight.** The defense against NOT NULL no-default is to block it at PR review since it will fail in PG anyway; couple with `ADD COLUMN NULL` + backfill + `SET NOT NULL VALIDATE` for online schema changes.
5. **MISSED: `schema.refresh.mode` Debezium setting** and how it relates to in-memory schema drift.
6. **MISSED: Iceberg ADD COLUMN nullability.** New columns added via ALTER TABLE ADD COLUMN in Iceberg are nullable; the answer mentions this but does not explain that Iceberg requires new columns to be nullable (a NOT NULL new column in Iceberg requires initial-default support in spec v2 and is not supported in Iceberg 1.5.2 via plain ALTER).
7. **MISSED: production-stack fit.** Trino 467 ALTER TABLE syntax, Hive Metastore backing, OPA implications for ALTER privilege — none surfaced. The answer is largely stack-agnostic.

## Resource fix recommendations
- `resources/13-postgres-to-iceberg-ingestion.md` should add a "Postgres DDL playbook for CDC pipelines" subsection covering:
  - Why `ADD COLUMN <col> NOT NULL` with no default on a populated table **fails** in Postgres (not "rewrites"); the safe online-schema-change pattern is `ADD COLUMN NULL` → backfill → `SET NOT NULL` (or `NOT NULL NOT VALID` then `VALIDATE CONSTRAINT` in PG 12+).
  - Which DDLs Debezium handles transparently (ADD COLUMN with non-volatile default in PG 11+ is metadata-only and a RELATION message arrives at the next change event).
  - Which DDLs trigger actual table rewrites and what that does (and does NOT do) to the WAL / replication slot.
- Add a callout that MERGE INTO column-drop vs. error behavior depends on `write.spark.accept-any-schema` + `mergeSchema`. Default Iceberg 1.5.2 Spark behavior is to error.
- Add the pause-ALTER-resume sequence, but tie it to the *actually-possible* DDL set (NOT NULL DEFAULT const, type widen, ADD COLUMN NULL, RENAME COLUMN), not to a scenario that errors in Postgres.
- Reference the Iceberg 1.5.2 limitation that ADD COLUMN produces a nullable column.

## Rubric update
Topic: **Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling**
- Prior running avg: 4.288 across 54 questions (from rubric line 3134).
- New running avg after this Q1: (4.288 × 54 + 3.0) / 55 = (231.552 + 3.0) / 55 = 234.552 / 55 ≈ **4.265** across 55 questions. Status: **PASSED** (>= 3.5 topic-level threshold), but the individual answer **FAILS** (3.0 < 3.5).
- Recommend teacher action this iteration since the false-premise pattern (inventing physics to fit a user's mistaken framing) is a regression — see Iter 52 Q1 (4.25) on the same Debezium-DDL theme where the responder handled it correctly.
