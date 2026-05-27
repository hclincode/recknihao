# Iter 78 Q1 — Judge Score
**Topic**: Postgres-to-Iceberg ingestion
**Score date**: 2026-05-25

| Dimension | Score |
|---|---|
| Technical accuracy | 5.0 |
| Beginner clarity | 4.75 |
| Practical applicability | 5.0 |
| Completeness | 5.0 |
| **Average** | **4.94** |

## Points covered
- **Point 1 (your scenario)**: Correctly states the job runs successfully and new rows get NULL for the new column. The "silent-omission case" framing is well-chosen.
- **Point 2 (opposite scenario)**: Correctly states `writeTo().append()` FAILS by default with a schema mismatch error (ValidationException) when the DataFrame has extra columns the Iceberg table lacks. This is the iter77 bug correctly fixed.
- **Point 3 (two opt-in knobs)**: Both `write.spark.accept-any-schema=true` (table property) and `.option("mergeSchema", "true")` (writer option) are explicitly mentioned as BOTH required.
- **Point 4 (separate schema systems)**: Clean explanation that Spark DataFrame schema (from JDBC query) and Iceberg table schema are separate and must be kept in sync manually.
- **Point 5 (fix)**: Concrete code shows updating the JDBC `SELECT` clause to include the new column.
- **Point 6 (historical NULL-fill)**: Correctly states "Iceberg fills in NULL for existing Parquet files automatically. No backfill required unless you want non-NULL values for historical rows." This is the iter18-q2 fix holding.
- **Point 7 (prevention)**: Preflight schema-diff check explicitly recommended to turn silent NULL into explicit alert.
- **Bonus**: Mental-model table at the end with four cases (including "explicit column list" silent-exclusion case) is excellent for a beginner.

## Issues
**None of substance.** Minor observations only:
- Could explicitly cite that `write.spark.accept-any-schema=true` is set via `ALTER TABLE ... SET TBLPROPERTIES (...)` — the answer just names the property without showing the SQL to set it. A SaaS engineer who wants to enable auto-evolution would need to look that up.
- The preflight check is mentioned but no concrete code snippet (e.g., querying `information_schema.columns` in Postgres vs `DESCRIBE TABLE` in Iceberg/Trino) is shown. Iter77 feedback flagged this gap was filled in other answers; here it remains conceptual.
- Production stack (Iceberg 1.5.2 on Hive Metastore, k8s, MinIO) is not surfaced, but the answer is fully compatible with it; no behavior described depends on a different environment.

## Accuracy verification
- DataFrame missing a column that Iceberg has → job succeeds, NULL written for that column — VERIFIED (Iceberg fills NULL for unset columns; metadata-only ADD COLUMN is documented at https://iceberg.apache.org/docs/1.5.1/evolution/).
- DataFrame with extra column Iceberg doesn't have → `writeTo().append()` fails with ValidationException — VERIFIED (https://iceberg.apache.org/docs/1.5.0/spark-writes/, PR #4154, issue #8005).
- Both `write.spark.accept-any-schema=true` table property AND `.option("mergeSchema","true")` writer option required for auto-evolution — VERIFIED (same sources).
- ALTER TABLE ADD COLUMN is metadata-only, no rewrite, existing rows return NULL automatically — VERIFIED (https://iceberg.apache.org/docs/1.5.1/evolution/).

## Resource fix needed?
**No.** The iter77 fix to `resources/13-postgres-to-iceberg-ingestion.md` (regarding default fail behavior + the two opt-in knobs) is clearly holding. Optional enhancement: add a small code snippet for the preflight schema-diff check (Postgres `information_schema.columns` vs Iceberg `DESCRIBE TABLE`), and show the SQL to set the `write.spark.accept-any-schema` table property. Neither is required for a pass.

## Updated topic average
Prior: 4.421 across 73 questions.
New: (4.421 × 73 + 4.94) / 74 = (322.733 + 4.94) / 74 = 327.673 / 74 ≈ **4.428** across 74 questions. Status: PASSED (>= 3.5).
