# Judge Score — Iter 85 Q2

## Score: 4.8125 / 5.0

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4.75 |
| Practical applicability | 5 |
| Completeness | 4.5 |

## Points covered (Postgres-to-Iceberg ingestion topic)

- Default schema-mismatch behavior: append fails (not silent drop), conservative-by-default Iceberg semantics.
- Safe migration sequence: ALTER Iceberg first, then re-run job.
- `ALTER TABLE ADD COLUMN` is metadata-only — no file rewrites, sub-second completion, works on a live table while readers/writers are active.
- Iceberg's column-ID model: old data files transparently return NULL for newly added columns.
- Auto-evolution knobs: `write.spark.accept-any-schema=true` (table property) + `.option("mergeSchema","true")` (writer option) — both required.
- Production stance: do NOT enable auto-evolution for incremental pipelines; reserves it for dev/ad-hoc use.
- Full-refresh distinction: `createOrReplace()` semantics flip the rule — never run ALTER, update the SELECT instead.
- Zero-downtime claim: no need to pause ingestion; ALTER + deploy + re-run sequence avoids the failure window.
- Preflight check recommendation: schema diff between Postgres `information_schema.columns` and Iceberg table schema, alerting before 2 AM page.

## Accuracy notes (WebSearch verification)

- **`writeTo().append()` fails by default with extra columns** — CONFIRMED. iceberg.apache.org/docs/latest/spark-writes and apache/iceberg#4542 both document the "Cannot write to [table], too many data columns" exception. No silent drop.
- **`ALTER TABLE ADD COLUMN` is metadata-only** — CONFIRMED. iceberg.apache.org/docs/latest/evolution explicitly states "schema updates are metadata-only changes" and "no data files are changed when you perform a schema update."
- **Old files return NULL for added columns** — CONFIRMED. Iceberg's column-ID assignment guarantees added columns "never read existing values from another column," and old files yield NULL when the new column is selected.
- **Both `write.spark.accept-any-schema=true` AND `mergeSchema=true` required** — CONFIRMED. iceberg.apache.org/docs/latest/spark-writes and apache/iceberg#8005 confirm both knobs must be set together; the table property opts in to the Spark DSv2 `ACCEPT_ANY_SCHEMA` capability bypassing Spark's validation, and the writer option `mergeSchema=true` then triggers Iceberg's `merge-schema` behavior. Answer's claim is correct.
- The answer's wording "extra columns in source dataframe" is paraphrased — the actual Iceberg error wording is closer to "Cannot write to [table], too many data columns". Minor cosmetic imprecision, not a factual error.

## Issues / gaps

1. **MERGE INTO not addressed.** The engineer's exact pipeline uses `MERGE INTO` (not `writeTo().append()`). The answer pivots to `append()` semantics without acknowledging that MERGE INTO behavior is different — `mergeSchema` is NOT supported on Spark `MERGE INTO` (apache/iceberg#5556). The same ALTER-first guidance still applies, but the engineer reading literally may not realize their MERGE pipeline cannot use the auto-evolution escape hatch even if they wanted to.
2. **No mention of the `WHERE updated_at >` semantics across the schema-change boundary.** Rows updated in Postgres around the cutover will have their new-column value picked up only if the watermark catches them — answer doesn't note that adding a column does not automatically backfill old rows even if their `updated_at` is older than the cutover. Minor backfill nuance left implicit.
3. **JDBC SELECT behavior not flagged.** If the user's JDBC source is `SELECT * FROM postgres_table` (not a pinned column list), the new column will silently appear in the DataFrame; if it's a pinned `SELECT col1, col2, ...` list, the column won't appear at all and Iceberg will not even see the change. The answer assumes the implicit `SELECT *` case without making the distinction. This affects whether the failure happens at all.
4. **No Trino/dbt cross-reference.** The production stack includes Trino + dbt. Worth noting Trino's `ALTER TABLE ADD COLUMN` syntax works against the same Iceberg table and is also metadata-only — engineers may run this from a dbt operation or Trino CLI rather than Spark.
5. **Iceberg 1.5.2 default-value support omitted.** Iceberg supports a DEFAULT clause on ADD COLUMN (initial-default + write-default in metadata) so old rows don't have to return NULL — useful for non-nullable columns or columns where NULL would break downstream dashboards. Not mentioned.
6. **Type/nullability sequencing nuance.** ALTER ADD COLUMN in Iceberg always adds as nullable; mention that adding a NOT NULL column requires a backfill + ALTER COLUMN SET NOT NULL sequence would round out the answer.
7. Minor: "milliseconds even on a 10 TB table" is true for the metadata write itself but the catalog round-trip (Hive Metastore in this prod stack) adds latency that's still well under a second — slight overstatement on speed.

## Production fit

Aligns with on-prem Spark + Iceberg 1.5.2 + Hive Metastore + MinIO stack. No cloud-only services referenced. ALTER TABLE syntax shown is valid in both Spark SQL and Trino against Iceberg. Catalog name `iceberg.analytics.events` is consistent with Trino's Hive-metastore-backed Iceberg connector naming.

## Resource fix needed?

Minor polish only — topic is well above pass threshold (4.454 across 78 questions; this answer pushes it higher). Suggested teacher actions:

- Add a section to `resources/13-postgres-to-iceberg-ingestion.md` explicitly contrasting `writeTo().append()` schema validation vs `MERGE INTO` schema validation, noting that `mergeSchema` is NOT supported on MERGE INTO (apache/iceberg#5556) — so for MERGE-based incremental pipelines, manual `ALTER TABLE` is the ONLY safe path.
- Add a one-line callout: the failure mode depends on whether the JDBC SELECT is `SELECT *` (column auto-appears, write fails) vs pinned `SELECT col1, col2, ...` (Iceberg never sees the change, silent skip until job code is updated).
- Add Iceberg DEFAULT-clause syntax (`ALTER TABLE ... ADD COLUMN ... DEFAULT ...`) for cases where NULL backfill isn't acceptable.
- Add a cross-reference that the same ALTER works from Trino (and from dbt via `{{ run_query() }}` or a post-hook) for teams that prefer running schema changes outside Spark.
- Note that ALTER ADD COLUMN always adds nullable; to make NOT NULL, you must backfill first then ALTER COLUMN.
