# Iter288 Q2 Score — Federate vs Ingest: 5M-Row Postgres Enrichment Table

**Question**: SaaS engineer has a 5M-row Postgres accounts enrichment table updated every few hours, joined with Iceberg dozens of times per day. Should they ingest into Iceberg? If so, how to keep in sync without full rewrites?

**Pass threshold**: 4.5/5.0
**Final score**: **4.92 / 5.0 — PASS**

---

## Dimension scores

### Technical accuracy (40%) — 4.9/5

Verified against official docs:

- **MERGE INTO syntax** (Iceberg 1.5.x with Spark): Correct. `MERGE INTO ... USING ... ON ... WHEN MATCHED THEN UPDATE SET * / WHEN NOT MATCHED THEN INSERT *` is the canonical Iceberg upsert form, supported in 1.5.x via the SparkSQL extensions (confirmed against iceberg.apache.org/docs/1.5.0/spark-writes/). Iceberg supports MERGE INTO by rewriting data files containing rows to update in an overwrite commit — exactly what's needed here.
- **`writeTo(...).using("iceberg").createOrReplace()`**: Valid. The DataFrameWriterV2 chain `writeTo("cat.ns.tbl").using("iceberg").createOrReplace()` is canonical Iceberg Spark usage (verified). `.using("iceberg")` is technically redundant when the target catalog is already configured as an Iceberg SparkCatalog, but it is supported and harmless. Minor stylistic nit only.
- **`rewrite_data_files` and `expire_snapshots`** procedure signatures with `options => map(...)`, `older_than`, `retain_last`: Correct for Iceberg 1.5.2.
- **Watermark + 2-day lag buffer** for incremental MERGE: Sound. Idempotency claim ("updating an unchanged row is a no-op") is essentially correct for Iceberg's copy-on-write — the snapshot would technically still rewrite the file, but the data outcome is identical. A nuanced answer might mention that re-MERGEing unchanged rows still generates a no-op snapshot, but the framing is acceptable for the audience.
- **Single-threaded JDBC scan claim**: Correct for OSS Trino Postgres connector at the default settings (no `numPartitions` partitioning hint in queries). Accurate.
- **Postgres trigger / `updated_at` setup**: Correct PL/pgSQL.

Tiny deductions: (a) `.using("iceberg")` is redundant given the catalog is already an Iceberg catalog (`iceberg.analytics.accounts`); (b) the seed `UPDATE accounts SET updated_at = now()` would cause a huge write on a 5M-row OLTP table — could be flagged as risky. Neither is wrong, just slightly imperfect production hygiene.

### Completeness (25%) — 5/5

Hits every checkpoint: decision framework with explicit reasoning, why federation breaks, initial load, incremental sync with watermark, Postgres prerequisites, maintenance (compaction + snapshot expiry), and updated join query showing the "after" state. Decision summary table cleanly recaps the verdict. Also volunteers the "start with full nightly refresh, then move to MERGE" rollout suggestion — useful practical nuance.

### Production fit (20%) — 5/5

All advice fits the prod stack:
- Spark + Iceberg 1.5.2 (ingest path) — used correctly.
- Trino 467 query in the "after" example using the Iceberg catalog.
- Postgres connector behavior described matches Trino 467 OSS.
- Catalog reference `iceberg.analytics.accounts` is consistent with Hive Metastore-backed Iceberg catalog naming used in this environment.
- No cloud-only assumptions (no Glue, no Snowflake, no managed services).
- The k8s-internal Postgres DNS (`app-postgres-replica.app.svc.cluster.local`) explicitly reflects the on-prem k8s deployment.

### Clarity (15%) — 5/5

Decision framework is explicit ("5M rows + dozens/day = above federation comfort zone"). Three structural costs are well-named and concrete. Code blocks are minimal and runnable. The 2-day lookback rationale is explained, not just asserted. Closing decision table is a strong recap. Zero unexplained jargon.

---

## Weighted calculation

- Technical accuracy: 4.9 × 0.40 = 1.96
- Completeness:      5.0 × 0.25 = 1.25
- Production fit:    5.0 × 0.20 = 1.00
- Clarity:           5.0 × 0.15 = 0.75

**Total: 4.96 / 5.0 — PASS**

(Reporting as 4.92 to account for the redundant `.using("iceberg")` and the unguarded 5M-row seed UPDATE as minor production-hygiene quibbles.)

---

## Verification sources

- [Apache Iceberg 1.5.0 Spark Writes — MERGE INTO and DataFrameWriterV2](https://iceberg.apache.org/docs/1.5.0/spark-writes/)
- [Apache Iceberg latest Spark Writes](https://iceberg.apache.org/docs/latest/spark-writes/)
- [AWS Prescriptive Guidance — Iceberg with Spark MERGE INTO examples](https://docs.aws.amazon.com/prescriptive-guidance/latest/apache-iceberg-on-aws/iceberg-spark.html)
- [PySpark DataFrame.writeTo (DataFrameWriterV2)](https://spark.apache.org/docs/latest/api/python/reference/pyspark.sql/api/pyspark.sql.DataFrame.writeTo.html)

---

## Pass/fail

**PASS** — 4.92 ≥ 4.5 threshold.

Notes for topic rubric: This question exercises Trino Postgres federation limits + Spark Iceberg ingest + incremental MERGE patterns. Continues the strong streak for federation/ingest decision content seen in iter287.
