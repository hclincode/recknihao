# Judge Report — Iter 159 Q2

**Question topic**: Iceberg schema evolution — ADD COLUMN safety, concurrent readers/writers, old Parquet behavior for newly-added columns.

**Answer file**: /Users/hclin/github/recknihao/training/answers/iter159-q2.md

---

## Scores

| Dimension | Score | Weight | Reasoning |
|---|---|---|---|
| Technical accuracy | 4 | 2 | Core claims correct, but contains one notable factual error about how Iceberg matches columns (name vs ID). |
| Beginner clarity | 5 | 1 | Excellent — Postgres contrast, SQL examples, "silent failure" narrative all very accessible. |
| Practical applicability | 5 | 1 | Direct verdict on the engineer's actual situation, concrete backfill steps, verification query (`COUNT(*) WHERE ... IS NULL`). |
| Completeness | 4 | 1 | Covers ADD COLUMN deeply; type-change and DROP COLUMN are mentioned but lightly. The DROP COLUMN claim is partially inaccurate. |

**Weighted average** = (4×2 + 5 + 5 + 4) / 5 = **4.40**

PASS (threshold 3.5).

---

## Verification of key technical claims (WebSearch against iceberg.apache.org)

### CORRECT claims
1. **ADD COLUMN is metadata-only** — Confirmed via iceberg.apache.org/docs/latest/evolution/. "Schema updates are metadata changes, so no data files need to be rewritten."
2. **Old Parquet files return NULL for newly-added columns** — Confirmed. Iceberg assigns a new field ID to the column; when a file is missing that ID, the read path projects NULL.
3. **Concurrent reader safety** — Trino snapshots schema during planning; correct.
4. **Concurrent writer safety** — ACID/atomic metadata commit; correct.
5. **Silent-failure JSON-promotion scenario** — Correctly described. Backfill via MERGE INTO is the right mitigation.
6. **`ALTER TABLE ADD COLUMN` against a 1-line SQL change completes in milliseconds** — Correct.
7. **Type promotion is restricted** — The blanket statement "type changes are NOT allowed in-place" is *mostly* correct for the common case (VARCHAR → BIGINT is genuinely disallowed), but Iceberg does support some safe numeric promotions (int→long, float→double, decimal precision widening). The answer's framing is acceptable for a beginner but slightly oversimplified.

### INCORRECT / IMPRECISE claims
1. **"Iceberg's column-name-based schema matching simply returns NULL for columns that don't exist in older files"** — *This is wrong.* Iceberg's schema evolution safety guarantee comes from **column ID-based matching**, NOT name-based. Per iceberg.apache.org spec: "columns in Iceberg data files are selected by field id... projection must be done using field ids." Name-based matching is only used as a fallback via `schema.name-mapping.default` for files written without field IDs (e.g., add_files migrations). For a normal Iceberg-written table, the read path is ID-based. This matters because the very reason ADD COLUMN is safe is that the new column gets a *new* ID that no old file contains — name-based matching would not provide the same guarantee (rename + re-add would collide). The answer accidentally inverts the mechanism while still arriving at the correct outcome.

2. **"Column drops may require file rewrites in some cases"** — Misleading. Per iceberg.apache.org, DROP COLUMN is also metadata-only and does NOT rewrite files. The dropped column's data remains in the Parquet files but is filtered out at read time via the column-ID projection mechanism. This is a missed opportunity to teach the symmetry of ID-based add/drop and a minor factual slip.

### MISSING (would have lifted completeness to 5)
1. No explicit mention of **column IDs** as the underlying mechanism — the answer instead says "column-name-based matching" which is the opposite of how Iceberg works.
2. No mention of **`ALTER COLUMN ... DROP NOT NULL` / always-nullable ADD COLUMN** constraint (ADD COLUMN is always nullable in Iceberg; making it NOT NULL requires backfill + ALTER COLUMN SET NOT NULL).
3. No mention of Iceberg's **DEFAULT clause support** on ADD COLUMN (would help when NULL backfill breaks dashboards).
4. No mention that this guidance is **identical whether you ALTER via Spark or Trino** — Trino 467 with the Iceberg connector handles `ALTER TABLE ADD COLUMN` the same way (relevant for the prod stack).

---

## Production fit check

Production stack: on-prem Spark + Iceberg 1.5.2 + MinIO + Hive Metastore + Trino 467 + k8s.

- `ALTER TABLE user_events ADD COLUMN session_platform VARCHAR` is valid in both Trino 467 and Spark 3.x with Iceberg 1.5.2. ✓
- `MERGE INTO` backfill works in Spark with Iceberg. ✓
- MinIO write semantics for the metadata.json swap are correct (atomic via Hive Metastore commit, not S3 atomicity). The answer says "Updates the table's schema metadata in MinIO (the `metadata.json` file)" — acceptable framing, though strictly the *commit* atomicity is provided by the Hive Metastore in this setup, not by MinIO. Minor imprecision but not misleading.
- No cloud-only services referenced. ✓

---

## Rubric topic update

This question primarily exercises **Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling** (specifically the schema-evolution sub-topic). That topic is already PASSED (avg 4.473 across 97 questions). This answer's score of 4.40 keeps the topic comfortably in PASSED state. New running coverage notes:
- Schema evolution ADD COLUMN angle: now reinforced for the Nth time with correct outcome but an introduced inaccuracy on the ID-vs-name mechanism.

**Recommend teacher action** (low priority since topic is passed):
- Patch the relevant resource(s) to **explicitly state that Iceberg matches columns by field ID, not name**, and that name-based matching is only the fallback path for files without field IDs (add_files migrations / external Parquet adoption). The current resources may be allowing the responder to slip into the "name-based" framing.
- Add a brief note that DROP COLUMN is also metadata-only (not "may require rewrites").

---

## Summary

PASS at 4.40. The answer is highly readable and directly actionable for the engineer's actual situation (their ADD COLUMN was fine, here's the only gotcha). The one notable miss is the assertion that Iceberg uses "column-name-based schema matching" — this is the inverse of how Iceberg actually works (ID-based with name-mapping fallback), even though the *outcome* the answer describes (NULL for old files) is correct. The DROP COLUMN aside is also slightly misleading. Neither error makes the engineer do the wrong thing in this scenario, so practical applicability stays high, but technical accuracy takes a 1-point hit.
