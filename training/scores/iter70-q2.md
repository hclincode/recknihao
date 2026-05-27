# Iter70 Q2 Score

## Scores
| Dimension | Score |
|---|---|
| Completeness | 5 |
| Accuracy | 5 |
| Clarity | 5 |
| No hallucination | 5 |
| **Final** | **5.00** |

## Points covered
All 5 required points fully addressed:
1. **Ingestion order matters (parent-first)** — Covered explicitly: "always ingest parent tables before child tables" with the users → orders → order_items sequence. Correctly notes Iceberg won't error on violations but queries will be wrong.
2. **Orphaned rows: INNER JOIN drops silently, LEFT JOIN misrepresents, no Trino error** — Covered with concrete SQL example showing how `WHERE o.order_id IS NOT NULL` silently drops orphans. Explicitly states "Trino does not error on orphaned child rows — it silently drops them from INNER JOINs and misrepresents them in LEFT JOINs."
3. **Idempotent fix: `overwritePartitions()` with fixed batch-date (not mutable watermark)** — Excellent treatment. Walks through the watermark failure scenario step by step (T1–T4), then prescribes the fixed batch_date pattern. Explains why this is stateless and idempotent.
4. **Run all related tables in a single Spark job** — Covered as its own section: "Don't create a DAG where users completes, then orders starts as a separate job..." with the single spark-submit pattern and all-or-nothing semantics.
5. **Monitoring with SQL reconciliation query; alert on count > 0** — Covered with `NOT EXISTS` orphan detection query, and a clear bullet list of root causes when the count > 0.

Bonus content: also addresses sub-day freshness via MERGE INTO + staggered watermarks (correctly flagged as more complex), and explicitly states Iceberg has no FK constraint enforcement.

## Issues found
WebSearch verification of all three accuracy concerns came back clean:

1. **`overwritePartitions()` semantics**: Confirmed correct. Per Apache Iceberg Spark Writes docs, the v2 API's `df.writeTo(t).overwritePartitions()` is "equivalent to dynamic INSERT OVERWRITE" and atomically replaces only the partitions present in the DataFrame. The answer's claim that re-running for the same batch_date produces identical state is accurate.
   - Source: https://iceberg.apache.org/docs/latest/spark-writes/
   - Source: https://spark.apache.org/docs/latest/api/python/reference/pyspark.sql/api/pyspark.sql.DataFrameWriterV2.overwritePartitions.html

2. **pgjdbc default fetchsize=0 means fetch all rows**: Confirmed correct. The default is 0, which loads the entire result set into memory. Demonstrated memory jumps from 6.67 MB to 454 MB without a non-zero fetchSize. The OOM warning is well-placed.
   - Source: https://shaneborden.com/2025/10/14/understanding-and-setting-postgresql-jdbc-fetch-size/
   - Source: https://franckpachot.medium.com/oracle-postgres-jdbc-fetch-size-3012d494712
   - Minor caveat the answer omits: cursor-based fetch requires autoCommit=false. Spark's JDBC reader sets this correctly under the hood, so it doesn't bite Spark users, but it's worth knowing. Not a hallucination — just a minor nuance.

3. **Iceberg does not enforce FOREIGN KEY constraints**: Confirmed correct. Iceberg supports an `identifier-field-ids` spec concept for primary key semantics (used for upsert), but does not enforce uniqueness, and there is no foreign key constraint mechanism at the table format level. Snowflake-managed Iceberg accepts FK syntax but does not enforce it.
   - Source: https://iceberg.apache.org/spec/
   - Source: https://github.com/apache/iceberg/issues/5069

Production fit: All advice fits the prod stack (Spark + Iceberg 1.5.2 + Hive Metastore + Trino 467 + MinIO + on-prem k8s). `overwritePartitions()` is the correct Spark API; single spark-submit job fits Spark on k8s; SQL reconciliation runs in Trino against the Iceberg catalog. No cloud-only services suggested.

No hallucinations. No incorrect claims. The pgjdbc autoCommit nuance is the only thing worth a teacher note, and it doesn't affect correctness.

## Resource fix needed?
No. This answer is exemplary across all dimensions and accurately reflects current Iceberg, Spark, and pgjdbc behavior. Optional minor enhancement: a future resource update could mention that Spark's JDBC reader sets autoCommit=false automatically so the fetchsize setting actually takes effect — but this is a nice-to-have, not a fix.
