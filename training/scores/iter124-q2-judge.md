# Iter124 Q2 — Judge Score

**Score**: 4.0 / 5 (Tech 3.5, Clarity 4.5, Practical 4.5, Completeness 3.5)

## Verdict
A well-organized, highly actionable answer that gives the engineer a complete 4-step recovery path (ALTER, fix source query, fix MERGE, backfill) plus a preflight check for prevention. The structure, code samples, and on-prem-friendly tone are strong. The technical accuracy is dented by an ambiguous claim about silent vs loud failure modes for `writeTo().append()` and MERGE INTO — the default Iceberg 1.5.x behavior with extra source columns is to FAIL with `AnalysisException: Cannot write to [table], too many data columns`, not to silently drop. Silent drop is the right description ONLY for the explicit-column-list MERGE case (Step 3). Despite this, the recommended remediation (ALTER first, then `UPDATE SET * / INSERT *`) is correct and matches official guidance.

## What was verified correct (via WebSearch)
- `ALTER TABLE ... ADD COLUMNS` is metadata-only with no data file rewrite — confirmed at iceberg.apache.org/docs/latest/evolution: "no data files are changed when you perform a schema update." Added column gets new ID; old files transparently return NULL.
- Backfilling history requires re-ingesting from Postgres into existing files (ALTER does not populate prior rows) — correct.
- `writeTo(...).append()` with extra DataFrame columns will throw `AnalysisException` ("too many data columns") by default — confirmed in iceberg.apache.org/docs/latest/spark-writes and apache/iceberg#4542. Answer hedges this as "may fail OR silently drop" which is partially incorrect (see below).
- `MERGE INTO ... UPDATE SET * / INSERT *` (i.e., `updateAll()`/`insertAll()`) maps by name; with both `write.spark.accept-any-schema=true` and `mergeSchema=true` it auto-evolves the target. Without those flags it does NOT silently drop — it surfaces the mismatch. After the explicit ALTER (Step 1), `* / *` correctly propagates new columns. The answer's *prescription* is right even though the framing ("Iceberg drops extra source columns") is misleading.
- `overwritePartitions()` is dynamic, partition-scoped (only partitions present in DataFrame are replaced), atomic, and effectively idempotent for fixed input — confirmed in iceberg.apache.org/docs/latest/spark-writes and PySpark DataFrameWriterV2 docs.
- Diagnostic `DESCRIBE iceberg.analytics.events` is valid Trino/Spark syntax.

## Errors or gaps
- **HIGH (Tech accuracy)**: The table on lines 19–24 states `writeTo(...).append()` "may fail with AnalysisException OR silently drop the column" and that `MERGE INTO with UPDATE SET * / INSERT *` "Column is silently dropped." Per official Iceberg docs and issue #4542, the default behavior is to FAIL LOUDLY ("Cannot write to [table], too many data columns"). Silent drop happens only with explicit column lists in the projection or MERGE (which IS correctly described in the third row). The engineer following the diagnosis logic could conclude their job is silently writing NULLs when in reality (a) the column never reached the DataFrame because the JDBC SELECT used an explicit column list, OR (b) the column exists in the DataFrame and they would see an error. The answer should also explicitly distinguish the `SELECT *` vs pinned-column-list JDBC pattern as the dominant cause of silent skips.
- **MEDIUM (Tech accuracy)**: The answer never cites the actual Iceberg error string ("Cannot write to [table], too many data columns"), so engineers grep'ing logs after their Spark job DOES surface the error won't find the resource hit.
- **MEDIUM (Completeness)**: `mergeSchema` is NOT supported on Spark `MERGE INTO` (apache/iceberg#5556). The answer says `UPDATE SET *` "automatically picks up new columns" — true only AFTER manual ALTER. Should be explicit: MERGE has no auto-evolution escape hatch, manual ALTER is the only safe path. Step 1 + Step 3 actually do the right thing, but the conceptual framing in the closing "core lesson" softens this important constraint.
- **MEDIUM (Completeness)**: `write.spark.accept-any-schema=true` table property + `option("mergeSchema","true")` writer option (the auto-evolution combo for `writeTo`) is not mentioned at all. Even if the answer's posture is "do manual ALTER" (correct), engineers will likely encounter this pattern elsewhere and should know it exists and why it's discouraged for incremental pipelines.
- **LOW (Completeness)**: No mention of Iceberg's `ALTER TABLE ... ADD COLUMN ... DEFAULT ...` (useful when NULL backfill breaks downstream dashboards). No mention that ADD COLUMN is always nullable in Iceberg.
- **LOW (Completeness)**: No CDC/Debezium framing despite the production stack including Debezium. The engineer said "Spark job that copies data from Postgres" which could be either JDBC batch or Debezium → Iceberg sink; the answer assumes JDBC. A one-line "if your pipeline is Debezium → Iceberg sink, the new column propagates when Debezium emits the next DML for the table; you still need ALTER on the Iceberg side" would close the gap.
- **LOW (Practical/prod fit)**: Preflight check uses `spark.sql(f"DESCRIBE TABLE {iceberg_table}")` which works, but on Trino-heavy shops the engineer may want the parallel Trino-side check via `SHOW COLUMNS FROM iceberg.analytics.events` for dbt or non-Spark workflows. Minor.

## Resource fix recommendations
- In `resources/13-postgres-to-iceberg-ingestion.md` schema-evolution section: replace any "may fail OR silently drop" hedging with the precise table:
  - JDBC `SELECT *` + `writeTo().append()` → fails loudly with "Cannot write to [table], too many data columns" (cite exact error string).
  - JDBC pinned `SELECT col1, col2, ...` + any writer → silent skip; Iceberg never sees the column. THIS is the dominant cause of "all NULLs after a Postgres column add."
  - `MERGE INTO` with `UPDATE SET * / INSERT *` BEFORE manual ALTER → fails (not silent drop); AFTER manual ALTER → propagates correctly.
  - `MERGE INTO` with explicit column list → silent skip (correct in answer).
- Add explicit callout: `mergeSchema` is NOT supported on Spark `MERGE INTO` per apache/iceberg#5556 — manual `ALTER TABLE ADD COLUMNS` is the only safe path for MERGE pipelines.
- Document `write.spark.accept-any-schema=true` + `mergeSchema=true` combo for `writeTo` only, with explicit "avoid for incremental pipelines because schema drift goes unaudited" warning.
- Add Debezium → Iceberg sink branch: when source is CDC (not JDBC batch), the new column arrives on next DML; still requires Iceberg-side ALTER unless sink connector has schema-evolution enabled.

## Topic state
**Topic touched**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling (prior avg 4.468 across 96 questions per current rubric).

**This question's score**: 4.0 — PASS (≥3.5 threshold). New running avg: (4.468 × 96 + 4.0) / 97 = (428.928 + 4.0) / 97 = 432.928 / 97 = **4.463** across 97 questions. Status: PASSED (well above 3.5 threshold). No topic-state demotion required, but the technical accuracy gap on `writeTo().append()` / MERGE silent-drop framing is a recurring weak spot (also flagged in Iter 85 Q2) and warrants a teacher polish pass on resource 13.
