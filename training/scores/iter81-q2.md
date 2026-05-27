# Iter 81 Q2 — Judge Score

**Topic**: Postgres-to-Iceberg ingestion
**Score date**: 2026-05-25
**Question**: Initial full-load of 200M-row Postgres table into Iceberg. Why does naive JDBC read cause OOM? What must be configured? Can you parallelize? How to resume if job crashes at 80%?

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All claims verified against official docs: pgjdbc default fetchsize=0 fetches all rows; Spark JDBC opens 1 connection by default; `partitionColumn`+`lowerBound`+`upperBound`+`numPartitions` enables parallel reads; `overwritePartitions()` is idempotent (validated as the default mode in Iceberg); `pushDownPredicate` exists with default `true`. Caveat about upperBound skew and uniform distribution requirement is correct. |
| Beginner clarity | 5 | Explains *why* it crashes (fetchsize=0 trap + no parallelism) before showing fix. No unexplained jargon. Code samples annotated inline. Distinguishes JDBC vs file-source behavior — important pedagogical clarification. Frames append vs overwritePartitions in terms of safety, not theory. |
| Practical applicability | 5 | Concrete code an engineer can paste and adapt. Production-relevant warnings: check `max_connections` before raising numPartitions, avoid skewed partition columns, run during off-hours, switch to incremental after backfill. Date-loop crash-recovery pattern is directly actionable. Fits the on-prem Spark + Iceberg + MinIO stack from prod_info.md (no cloud-only tools referenced). |
| Completeness | 5 | Covers all four parts of the question: (1) why OOM, (2) required config, (3) parallelism, (4) crash recovery. Plus migration checklist as bonus. Mentions watermark+append/MERGE for ongoing sync as the post-migration step. |
| **Average** | **5.00** | |

## Points covered
1. Root cause of OOM (fetchsize=0 fetches all rows): YES — explained as "the JDBC fetchsize trap" with the exact pgjdbc behavior.
2. Single connection by default — no parallelism: YES — called out as Problem 1.
3. `partitionColumn` + `lowerBound` + `upperBound` + `numPartitions`: YES — full code example with explanation.
4. `fetchsize=10000` as memory safety valve: YES — explicitly labeled as such.
5. `overwritePartitions()` makes batches idempotent: YES — explained with date-loop pattern.
6. `.append()` NOT idempotent (causes duplicates on rerun): YES — labeled "Dangerous approach".
7. Migration checklist (date batches, off-hours, switch to incremental): YES — full numbered checklist at the end.

## Issues
- Minor: Did not mention pgjdbc's auto-commit requirement (fetchsize is ignored in auto-commit mode unless `autoCommit=false`). Spark's JDBC reader handles this internally, so it isn't an action item for the engineer, but a thorough answer could mention this gotcha. Not deducting — not blocking for the asked use case.
- Could briefly note that for the on-prem MinIO/Iceberg/HMS stack, the writeTo target needs a Hive catalog mapping (e.g., `spark.sql.catalog.iceberg=...`). Implicit but not stated. Minor.

## Accuracy verification (WebSearch)
- pgjdbc default fetchSize=0 fetches all rows into memory: CONFIRMED (shaneborden.com, pgjdbc threads).
- Spark JDBC `partitionColumn` requires numeric/date/timestamp column: CONFIRMED (spark.apache.org).
- `overwritePartitions()` default validation mode is idempotent: CONFIRMED (iceberg.apache.org Spark writes docs).
- `pushDownPredicate` JDBC option default=true: CONFIRMED (spark.apache.org JDBC docs).

## Resource fix needed?
No. The answer is materially correct, fits the production stack, and is one of the strongest Postgres-to-Iceberg answers in the training set. Resources are evidently in good shape for this angle.

## Updated topic average
Prior: 4.435 / 75 questions
This score: 5.00
New running avg: (4.435 * 75 + 5.00) / 76 = **4.4424 / 76 questions** — Status: PASSED.
