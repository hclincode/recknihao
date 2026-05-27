# Judge Score — Iter 326 Q1

## Scores
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All four key claims verified against official docs. `ALTER TABLE ... ADD COLUMN metadata.sso_enabled BOOLEAN` is the correct Iceberg dotted-path DDL (verified against iceberg.apache.org Spark DDL: `ALTER TABLE prod.db.sample ADD COLUMN point.z double`). Trino supports this nested ADD COLUMN form since release 422 (Jul 2023), so Trino 467 supports it. Metadata-only / NULL-for-old-rows is correct per Iceberg spec — field ID matching means absent IDs in old files resolve to null. `col("metadata").withField("sso_enabled", value)` is valid PySpark 3.1.0+. `ALTER COLUMN metadata ADD sso_enabled` is correctly identified as invalid Iceberg DDL. |
| Beginner clarity | 4.5 | Strong organization: leads with the answer, then explains why, then shows the alternative. Field-ID mechanism explained accessibly. The "dashboards show zero historical data with no obvious error" framing makes the NULL gotcha concrete. Minor: the comparison table and operations list assume familiarity with terms like "metadata-only" and "field ID" — adequately defined inline but a complete beginner might still need to re-read. |
| Practical applicability | 5 | Engineer can copy/paste the DDL, the Spark struct-rebuild pattern, and the backfill snippet directly. Production stack fit is excellent: explicit Trino 467 mention, Spark + MinIO/Parquet references, Hive-Metastore-compatible operations, no cloud-only tooling. The 4-step rollout timeline at the end converts the conceptual answer into an actionable runbook. Verification SELECT is a nice touch. |
| Completeness | 5 | Addresses every part of the question: (1) correct DDL syntax, (2) why the attempted syntax failed, (3) what happens to old rows, (4) Trino 467 specifics, (5) Spark ingestion update, (6) optional backfill, (7) nullable constraint warning, (8) comparison vs top-level columns. No important nuance missing for a STRUCT-field-addition workflow. |
| **Average** | **4.875** | **PASS** |

## What Worked
- Leads with the exact one-line DDL the engineer needs — no preamble.
- Explicitly addresses *why* the attempted `ALTER COLUMN ... ADD` form fails — closes the loop on the actual error the engineer hit.
- Field-ID explanation correctly grounded in the Iceberg spec and ties together why ADD/DROP/RENAME are all metadata-only.
- Backfill snippet uses `col("metadata").withField(...)` which is the idiomatic PySpark 3.1.0+ approach (verified).
- The "WHERE metadata.sso_enabled = true silently excludes historical rows" warning is the single most useful operational note in the answer.
- Production-stack fit: Trino 467, Spark, MinIO/Parquet all named correctly.

## What Missed
- Minor: could mention that the new field will appear at the *end* of the struct (Iceberg appends by default) rather than at a specified ordinal position — only matters if the engineer cares about struct field ordering for serialization.
- Minor: backfill snippet uses `.overwritePartitions()` which assumes the table is partitioned in a way that the whole table can be rewritten in one go; for very large `events` tables a partition-by-partition or merge-into pattern would be safer. Not wrong, just slightly under-qualified for production-scale.
- The note "you cannot add a NOT NULL nested field via ADD COLUMN" is technically correct for the typical path but glosses over the Iceberg v2+ default-value feature (`SET DEFAULT`) that exists in newer Iceberg versions — for Iceberg 1.5.2 (the prod version), this caveat is correct as written, so not a deduction.

## Technical Accuracy (verified)
1. **Dotted-path ADD COLUMN for nested struct fields**: VERIFIED. Iceberg Spark DDL docs show `ALTER TABLE prod.db.sample ADD COLUMN point.z double` as the canonical form. The answer's `ADD COLUMN metadata.sso_enabled BOOLEAN` matches this pattern exactly.
2. **Metadata-only, old rows return NULL**: VERIFIED. Iceberg spec: "if a field id is missing from a data file, its value for each row should be null." Adding a struct sub-field assigns a new field ID; old Parquet files don't have a column chunk for that ID, so the reader returns null with no rewrite.
3. **`col("metadata").withField("sso_enabled", value)` PySpark**: VERIFIED. Official PySpark docs (3.1.0+) document `Column.withField(fieldName, value)` for adding/replacing a struct field. Example from docs: `df.withColumn('a', df['a'].withField('d', lit(4)))`.
4. **`ALTER COLUMN metadata ADD sso_enabled` is invalid**: VERIFIED. Neither Iceberg Spark DDL nor Trino's ALTER TABLE syntax exposes an `ALTER COLUMN ... ADD <field>` form. The Trino GitHub discussion (#16897) confirms the proposed/supported syntax uses `ADD COLUMN` with a dotted path, not `ALTER COLUMN ... ADD`. Trino release 422 (Jul 2023) added support for nested-field ADD COLUMN, so Trino 467 supports it.

Sources:
- [Iceberg Spark DDL](https://iceberg.apache.org/docs/latest/spark-ddl/)
- [Iceberg Schema Evolution](https://iceberg.apache.org/docs/1.5.1/evolution/)
- [Iceberg Spec — field ID resolution](https://iceberg.apache.org/spec/)
- [PySpark Column.withField](https://spark.apache.org/docs/latest/api/python/reference/pyspark.sql/api/pyspark.sql.Column.withField.html)
- [Trino Managing Nested Fields discussion](https://github.com/trinodb/trino/discussions/16897)
- [Trino Release 422 — nested ADD COLUMN support](https://trino.io/docs/current/release/release-422.html)

## Rubric Update
- Postgres-to-Iceberg ingestion: prior avg 4.490 across 115 questions → (4.490 × 115 + 4.875) / 116 = **4.493 across 116 questions**. Status: **PASSED**.
