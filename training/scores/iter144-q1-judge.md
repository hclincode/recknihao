# Iter144 Q1 — Judge Score

**Question topic**: Iceberg column rename safety, field-ID mechanism, old Parquet file readability, downstream impact, Debezium/CDC implications.

**Production stack alignment**: Trino 467, Iceberg 1.5.2, MinIO, Hive Metastore, Debezium 2.x, Spark — answer respects this stack.

---

## Score Breakdown

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 5 | All core claims verified against Iceberg spec and Trino docs. |
| Clarity for SaaS engineer | 5 | Plain-language explanation; field-ID concept introduced before jargon; concrete example of `SELECT account_id FROM events`. |
| Practical usefulness | 5 | Correct Trino DDL, explicit list of downstream things to fix, post-rename sanity check, CDC sequence. |
| Completeness | 5 | Covers metadata-only behavior, old files, downstream breakage (Spark, dbt, views, BI, ORM), and the Debezium pipeline. |

**Average = (5 + 5 + 5 + 5) / 4 = 5.0** → **PASS** (threshold 4.5)

---

## Verified Correct (via WebSearch)

1. **Field-ID mechanism**: Iceberg tracks columns by unique integer field IDs assigned at column creation, persisted in both table metadata and Parquet file metadata. Readers project by field ID, not by name. Source: iceberg.apache.org/docs/latest/evolution/, iceberg.apache.org/spec/.
2. **RENAME COLUMN is metadata-only**: "Iceberg schema updates are metadata changes, so no data files need to be rewritten to perform the update." Renaming changes the name in metadata; the field ID stays the same so existing data files still map correctly. Confirmed for 1.5.x line.
3. **Trino syntax**: `ALTER TABLE [IF EXISTS] name RENAME COLUMN [IF EXISTS] old_name TO new_name` — exactly what the answer shows. The fully-qualified `iceberg.analytics.events` form is correct in Trino 467 with the Iceberg connector.
4. **Old files transparent after rename**: confirmed — readers locate columns by field ID, so two-year-old Parquet files in MinIO continue to work without rewrite.
5. **DROP COLUMN similarly safe** (not directly asked but referenced conceptually as a Iceberg safe metadata op): also field-ID based, metadata-only.
6. **Debezium/CDC sequence**: Operationally sound. Stopping the Spark consumer, doing the Iceberg rename, then the Postgres rename, then updating consumer logic, then resuming — this avoids `account_id` events arriving before the consumer or Iceberg column exists. Note: Debezium for Postgres detects relation changes on next DML; the answer's framing is reasonable. The point that wildcard MERGE syntax auto-adapts vs explicit lists requiring update is accurate.

---

## Errors or Gaps Found

None material. Minor observations only:

- The Postgres-side WAL behavior on rename is slightly more nuanced than stated — Postgres logical replication doesn't always emit an explicit DDL event for renames; downstream sees the new RELATION on the next DML. The answer's wording ("detects the Postgres-side column rename via WAL RELATION messages on the next DML") is acceptable shorthand.
- Could have mentioned that `Iceberg` also supports column rename via Spark `ALTER TABLE ... RENAME COLUMN` for completeness, but the question was Trino-scoped so omission is fine.
- Could briefly note that even though Parquet files are untouched, OPA policies referencing the old column name would also need updating — but this is implicitly covered by "application code with column name mappings".

---

## Resource Fix Recommendations

None required. The schema-evolution resource (whichever produced this answer) is performing at top level. Both Q1 phrasing tests (field-ID transparency + downstream-impact + CDC) returned a correct, complete, well-structured answer.

---

## Verdict: **PASS** (5.0 / 5.0)

Sources verified:
- [Apache Iceberg — Evolution](https://iceberg.apache.org/docs/latest/evolution/)
- [Apache Iceberg — Spec (field IDs)](https://iceberg.apache.org/spec/)
- [Apache Iceberg — DDL (Spark)](https://iceberg.apache.org/docs/latest/spark-ddl/)
- [Trino — ALTER TABLE](https://trino.io/docs/current/sql/alter-table.html)
- [Trino — Iceberg connector](https://trino.io/docs/current/connector/iceberg.html)
- [Starburst — Apache Iceberg Schema Evolution in Trino](https://www.starburst.io/blog/apache-iceberg-schema-evolution-in-trino/)
- [Debezium PostgreSQL connector docs](https://debezium.io/documentation/reference/1.9/connectors/postgresql.html)
