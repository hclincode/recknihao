# Iter 77 Q1 — Judge Score
**Topic**: Postgres-to-Iceberg ingestion
**Score date**: 2026-05-25

| Dimension | Score |
|---|---|
| Technical accuracy | 3.0 |
| Beginner clarity | 4.5 |
| Practical applicability | 3.5 |
| Completeness | 4.0 |
| **Average** | **3.75** |

## Points covered
- Correctly forks the answer on incremental vs full-refresh patterns (Point 1).
- Correctly identifies that `createOrReplace()` rebuilds the table on every run and that the new column will silently disappear next run if Spark code doesn't include it (Point 3).
- Correctly warns against `ALTER TABLE` on full-refresh tables (Point 4).
- Correctly states that Iceberg schema evolution NULL-fills historical rows for added columns (Point 5).
- Provides an actionable grep recipe to identify which pattern the job uses (Point 6).
- Clear per-pattern recommendation table at the end (Point 7).
- Beginner-friendly tone, mental-model table, concrete code snippets.

## Issues
**Major technical inaccuracy on the incremental/append path (Point 2).** The answer asserts:
> "The job did not crash. … The new column was written to Iceberg. Iceberg's schema evolution is column-name-based — it accepted the new column automatically."

This is **wrong by default**. With the standard Iceberg 1.5.2 + Spark DataFrameWriterV2 configuration in the production stack:
- A `df.writeTo(...).append()` call where the DataFrame has an extra column **not** present in the Iceberg table schema will **fail with a schema-mismatch/validation error** (the job DOES crash) — it does not silently auto-add the column.
- To get the described auto-evolution behavior the user must BOTH set the table property `write.spark.accept-any-schema=true` AND pass `.option("mergeSchema", "true")` on the writer. Neither is mentioned.
- Without those, the safe answer is either (a) the job crashed and you need to run `ALTER TABLE … ADD COLUMN` first (then optionally turn on mergeSchema), or (b) the job kept succeeding because Spark's JDBC reader silently dropped the new column when the existing target schema was used to project the read — which depends on how the JDBC source schema is resolved.

The answer also confuses cause-and-effect on the "SELECT *" branch. If the job already runs with `SELECT *` and the new column flowed in, by default `writeTo().append()` would fail; the only way it does NOT crash is if the explicit column list was used (and then the column was silently excluded — the OPPOSITE of what the answer claims).

**Smaller issues:**
- "Iceberg's schema-evolution guarantee" for historical NULL-fill is correct, but the answer ties this to the append path "accepting" the new column, which doesn't happen by default.
- Does not mention `write.spark.accept-any-schema` or `mergeSchema` anywhere — these are the actual levers a SaaS engineer needs to set on Iceberg 1.5.2.
- Production stack uses Iceberg 1.5.2 + Hive Metastore on on-prem k8s; the answer doesn't note that ALTER TABLE ADD COLUMN via Spark SQL (`spark.sql("ALTER TABLE ... ADD COLUMNS (new_col STRING)")`) is the most common manual remediation, even for incremental jobs.
- "The job did not crash" is stated as fact rather than as a conditional — for the engineer who is troubleshooting RIGHT NOW, this could be misleading if their job in fact did crash.

## Accuracy verification
- Iceberg schema evolution NULL-fills existing rows for newly added columns — VERIFIED (https://iceberg.apache.org/docs/1.5.1/evolution/).
- `writeTo().createOrReplace()` replaces schema and partition spec to match the incoming DataFrame — VERIFIED (https://iceberg.apache.org/docs/latest/spark-writes/).
- `writeTo().append()` does NOT auto-add new columns by default — requires `mergeSchema=true` + `write.spark.accept-any-schema=true` table property — VERIFIED via official docs and Iceberg PR #4154 / issue #8005. The answer's claim that incremental jobs "auto-pick up the new column" with no setup is **incorrect** for default Iceberg 1.5.2 behavior.

## Resource fix needed?
**Yes.** `resources/13-postgres-to-iceberg-ingestion.md` (or equivalent) should:
1. State explicitly that `writeTo().append()` does NOT auto-evolve schema by default — it will fail on new columns.
2. Document the two Iceberg knobs: `write.spark.accept-any-schema=true` (table property) and `.option("mergeSchema", "true")` (writer option).
3. Show the manual `ALTER TABLE … ADD COLUMN` remediation path as the conservative default for shops that don't want auto schema evolution.
4. Clarify what actually happens when the JDBC source has extra columns and the Spark code uses `SELECT *` vs explicit column list.

## Updated topic average
Prior: 4.430 across 72 questions.
New: (4.430 × 72 + 3.75) / 73 = (318.96 + 3.75) / 73 = 322.71 / 73 ≈ **4.421** across 73 questions. Status: PASSED (>= 3.5).
