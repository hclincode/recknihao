# Iter138 Q1 — Judge Evaluation

**Question**: RENAME COLUMN behavior on historical Parquet files in Iceberg; DROP COLUMN physical deletion of PII data.

**Topics touched**:
- Lakehouse schema design (column rename / drop semantics)
- Iceberg table maintenance (rewrite_data_files, expire_snapshots, remove_orphan_files)
- Postgres-to-Iceberg ingestion (indirect — schema evolution)

---

## Score summary

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4 | Core Iceberg semantics correct; one concrete syntax bug on `retention_threshold => '1d'` that will FAIL in default Trino 467 (7-day floor). |
| Beginner clarity | 5 | Field-ID table with before/after diagrams; summary table at the bottom; jargon defined inline; explicit "you will NOT see NULLs" callout. |
| Practical applicability | 4 | Three-step PII purge is actionable and engine-labeled (Spark CALL for rewrite, Trino EXECUTE for expiry/orphan). Loses 1 point because the `'1d'` retention values would fail in production Trino 467 without lowering `iceberg.expire-snapshots.min-retention` — and that requirement is not mentioned. |
| Completeness | 5 | Covers both halves of the question (rename + drop), explains the field-ID mechanism, covers the data-still-on-MinIO risk vector (direct Spark/Arrow read), covers the three-step purge, AND adds an edge-case section on when NULLs do appear (ADD COLUMN, JSON promotion, register_table). |
| **Overall** | **4.50 / 5** | |

**Verdict**: **PASS** (>= 4.0 threshold).

---

## What was verified correct (against official docs)

1. **Iceberg uses field IDs, not column names** — confirmed via iceberg.apache.org/docs/latest/evolution/ and iceberg.apache.org/spec/. "Iceberg uses unique IDs to track each column in a table. The table schema's column names and order may change after a data file is written, and projection must be done using field ids." Matches the answer's core thesis.

2. **RENAME COLUMN is metadata-only, no Parquet rewrite** — confirmed: "Iceberg schema updates are metadata changes, so no data files need to be rewritten." Matches.

3. **Historical data after RENAME returns under the new name, NOT NULL** — confirmed via field-ID projection guarantee. Answer's claim "You will NOT see NULLs" is correct.

4. **DROP COLUMN is metadata-only, PII data remains in Parquet files** — confirmed: "When you drop a column in Iceberg, the column is gone from the schema, but the data still exists in the Parquet files, and Iceberg no longer exposes it." Matches.

5. **PII still readable via direct MinIO/Parquet access** — correct interpretation of the immutable-file model. A raw Parquet reader bypasses Iceberg schema and can read field ID 7.

6. **Three-step purge: rewrite_data_files → expire_snapshots → remove_orphan_files** — order and necessity confirmed against iceberg.apache.org/docs/latest/maintenance/ and resources/17. Each step is needed: rewrite produces new files without the dropped column, expire releases the old snapshots' hold on the old files, orphan removal physically deletes the bytes from MinIO.

7. **ADD COLUMN causes NULLs on historical rows** — correct. Iceberg assigns a new field ID; old files have no data for it.

8. **Trino 467 named-arg syntax `EXECUTE expire_snapshots(retention_threshold => '...')` and `EXECUTE remove_orphan_files(retention_threshold => '...')`** — syntax form is correct per trino.io/docs/current/connector/iceberg.html.

9. **rewrite_data_files is engine-labeled as Spark CALL** — correctly distinguished from Trino's `ALTER TABLE ... EXECUTE optimize` form. (Note: Trino 467 has its own `EXECUTE optimize`, but the answer's choice of Spark CALL for the rewrite step is valid and the answer correctly does NOT mislead the reader into thinking it's Trino syntax.)

---

## Errors / gaps

### MEDIUM — `retention_threshold => '1d'` will FAIL in default Trino 467

The answer's Step 2 (`expire_snapshots(retention_threshold => '1d')`) and Step 3 (`remove_orphan_files(retention_threshold => '1d')`) use `'1d'` values. Trino's Iceberg connector enforces a default minimum of `7d` for both:
- `iceberg.expire-snapshots.min-retention` default = `7d`
- `iceberg.remove-orphan-files.min-retention` default = `7d`

Trino REJECTS values below the floor with an explicit error. resources/17 explicitly calls this out (lines 64–70). The reader will copy-paste this and immediately get a procedure failure.

For a GDPR/PII same-day purge, the answer should either:
- Use `'7d'` and explain the engineer must accept a 7-day delay, OR
- Switch to Spark CALL syntax for expire_snapshots (Spark has no min-retention floor), OR
- Tell the engineer to lower the catalog config `iceberg.expire-snapshots.min-retention=0d` for the operation.

This is the same persistent pattern flagged in prior iterations (see rubric line 2067). The answer used the correct ALTER TABLE EXECUTE syntax but missed the floor.

### LOW — Trino native `EXECUTE optimize` not mentioned as alternative to Spark CALL for rewrite_data_files

Trino 467 has `ALTER TABLE ... EXECUTE optimize` which performs the same role as Spark's `rewrite_data_files`. The answer goes straight to Spark CALL syntax. For a Trino-first user this is an extra context switch. Not wrong, but resources/17 explicitly says "You do NOT need Spark for routine compaction." A nudge toward the Trino-native path would help.

### LOW — `rewrite-all => true` option phrasing

The "guaranteed full purge" code block uses `'rewrite-all', 'true'` as a string-string map entry. The actual Iceberg Spark procedure option is `where` (filter) for partial rewrites, and `rewrite-all` is sometimes passed via the options map but the canonical way to force full rewrite is `where => '1=1'` or rewriting strategies (`sort`/`zorder`). Minor — the intent (force a full rewrite) is clear and the reader will figure it out, but the option name is not exactly the standard one in Iceberg 1.5.2 Spark procedures.

### LOW — Doesn't mention that metadata files (Avro manifest lists) may also still reference field ID 7

The answer correctly says new Parquet files are clean after rewrite_data_files. It doesn't mention that older metadata files (manifest lists, manifest Avro files) in the table's metadata directory may still embed the old schema versions referencing the dropped field's name and type. For strict PII compliance, expire_snapshots with `clean_expired_metadata => true` (Trino) is also relevant. Minor omission, not technically wrong.

---

## Resource fix recommendations

1. **resources/17-iceberg-table-maintenance.md** — add a GDPR/PII same-day purge worked example showing how to handle the 7-day floor. The current resource calls out the floor in the cheat sheet but does not connect it to the PII-deletion workflow. Add a sidebar: "If you need to delete in less than 7 days, here are your three options: (a) Spark CALL syntax — no floor; (b) lower `iceberg.expire-snapshots.min-retention` in your Trino catalog config; (c) accept the 7-day window and use Trino-native."

2. **resources/09-lakehouse-schema-design.md** — verify it has a clear section on field-ID-based schema evolution (RENAME = safe, DROP = data persists). The answer was strong here, suggesting the resource is adequate — but check that the "DROP COLUMN does NOT delete PII from MinIO" warning is prominent and links to resource 17's three-step purge.

3. **Persistent pattern**: judge has now flagged the `retention_threshold` floor issue multiple times across iterations. Teacher should consider a top-of-resource-17 callout box that every code sample using `retention_threshold => 'Xd'` is checked against the 7-day floor.

---

## Sources

- [Apache Iceberg Evolution docs](https://iceberg.apache.org/docs/latest/evolution/)
- [Apache Iceberg Spec — field IDs and schema evolution](https://iceberg.apache.org/spec/)
- [Apache Iceberg Maintenance docs](https://iceberg.apache.org/docs/latest/maintenance/)
- [Apache Iceberg Spark Procedures](https://iceberg.apache.org/docs/latest/spark-procedures/)
- [Trino Iceberg connector — ALTER TABLE EXECUTE syntax and retention floor](https://trino.io/docs/current/connector/iceberg.html)
