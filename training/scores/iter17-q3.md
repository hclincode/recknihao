# Score: Iteration 17, Question 3

**Date**: 2026-05-24
**Phase**: Final
**Question**: Enterprise customer wants a full 3-year data export. SELECT * WHERE tenant_id = 'bigcorp' times out. What's the right way?
**Rubric topics**: Multi-tenant analytics; Analytical query patterns on Iceberg+Trino

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.0 | Core pattern correct: INSERT INTO temp table then download Parquet files directly from MinIO. Why SELECT * times out correctly explained (reads all columns, coordinator memory bottleneck, network serialization). Partition pruning explanation (bigcorp's tenant partition narrows files but all columns still read) is correct. However: the answer attributes the CTAS to "Spark" — "Spark handles the heavy lifting." In this production stack, CREATE TABLE AS SELECT runs via Trino 467, not Spark. Trino does the parallel reads and writes to Iceberg files in MinIO via the Iceberg connector. This is a moderate engine-attribution error. |
| Beginner clarity | 4.75 | Excellent "what Trino is doing behind the scenes" numbered list. Direct MinIO download explanation is concrete. Checklist at end is actionable. |
| Practical applicability | 4.50 | The INSERT INTO + MinIO download pattern is exactly what prod_info.md documents as the supported export pattern. Direct MinIO access via `mc cp` is correct for the on-prem MinIO setup. DROP TABLE cleanup is correct. Engine misattribution reduces score slightly. |
| Completeness | 4.50 | Covers timeout cause (3 reasons), INSERT INTO pattern, direct MinIO download, why partitioning helps (but not fully), cleanup. Minor gap: doesn't mention that the CTAS is a Trino operation (not Spark), and doesn't note that the temp table lives in MinIO at a predictable path under the warehouse directory. |
| **Average** | **4.44** | |

---

## What the answer got right

1. SELECT * timeout: reads all columns (columnar storage ≠ row dump), coordinator memory, network serialization — all correct.
2. INSERT INTO iceberg.temp.bigcorp_export AS SELECT... — correct pattern, matches prod_info.md documentation.
3. Direct MinIO download as faster alternative to streaming through Trino — correct.
4. mc cp parallel download — correct for on-prem MinIO.
5. DROP TABLE cleanup — correct.

## What the answer got wrong

1. **"Spark handles the heavy lifting" for CTAS.** The CREATE TABLE AS SELECT query is executed by Trino 467 via the Iceberg connector. Trino has distributed workers that parallelize the read+write. Spark is not involved in ad-hoc Trino queries. This is a clear engine-attribution error.

## Resource gap note

`resources/05-multi-tenant-analytics.md` or `resources/04-data-lakehouse.md` should clarify that ad-hoc large exports use Trino CTAS (not Spark CTAS). Consider adding a note: "INSERT INTO ... SELECT runs in Trino 467, which distributes the work across Trino worker nodes and writes results as Parquet files to MinIO. This is a Trino operation, not Spark."

## Topic score updates

**Multi-tenant analytics**
- Prior: avg ~3.969 across 13 questions
- This answer: 4.44 (14th angle — data export pattern)
- New running avg: (51.597 + 4.44) / 14 = **4.003** across 14 questions
- Status: PASSED (crossed 4.0 milestone)
