# Iter258 Q2 Score

**Score: 4.9 / 5.0** — PASS (threshold: 4.5)

## What was correct
- Confirmed Trino can join Postgres + MySQL + Iceberg in a single SQL statement; example query is valid (correct three-part `catalog.schema.table` naming).
- Correctly states the join itself runs inside Trino workers and that no "cross-catalog join pushdown" exists. Each source is unaware of the others.
- Correctly explains per-catalog predicate pushdown still applies independently — WHERE clauses against each source are evaluated server-side where the connector supports it.
- Correctly identifies the MySQL VARCHAR/text pushdown limitation. Verified against trino.io MySQL connector docs: textual predicates (CHAR/VARCHAR) are NOT pushed because MySQL's default collation is case-insensitive and pushing them could cause incorrect results. The answer's "WHERE status = 'paid'" example is accurate.
- Correctly identifies the JDBC single-split limitation for non-partitioned tables. Verified: non-partitioned JDBC tables return a single split → one JDBC connection → single-threaded scan. This is a well-known Trino bottleneck (Starburst's "JDBC bottleneck" articles).
- Dynamic filtering description is technically sound: build side (small JDBC dimension) feeds an IN-list/Bloom filter into the probe side (large Iceberg fact); Iceberg can prune Parquet files via manifest statistics.
- The build/probe orientation recommendation (Iceberg as probe, small JDBC as build) matches Trino best practice.
- `iceberg.dynamic-filtering.wait-timeout` default of 1s is verified accurate per trino.io Iceberg connector docs. Raising it to give slow JDBC build sides time is a legitimate recommendation.
- The "federation is read-only / no distributed transaction" caveat is correct.
- Materialization advice (ingest large JDBC table to Iceberg) is the right architectural escape hatch for the production stack (Spark + Iceberg + MinIO).
- Fits the prod_info.md environment (Trino 467 + Iceberg + Hive Metastore on k8s on-prem).

## Gaps or errors
- The "4–8 minutes" planning-time claim under "Planning complexity grows with more catalogs" is presented as a typical number but is not backed by a Trino-documented baseline. In practice, multi-catalog planning is usually sub-second to a few seconds; minutes-long planning is an outlier (often caused by metastore latency or expensive `information_schema` lookups against bloated JDBC catalogs). Slight overstatement, not a critical error.
- The "50K–200K rows/second" single-JDBC throughput figure is a rough rule of thumb, not a verified Trino published number. Real throughput varies widely by network, source DB load, and row width. Minor imprecision.
- Could have mentioned that dynamic filtering between Trino and Iceberg specifically benefits from Iceberg's partition/min-max manifest statistics — the answer says "manifest-level statistics" but does not explicitly note bucket/partition pruning vs file-level min/max pruning. Minor nuance gap.
- No mention that dynamic filtering can also push *into* JDBC build sources (since Trino 388+, JDBC connectors support `dynamic-filtering.enabled` and `dynamic-filtering.wait-timeout` themselves). The answer treats JDBC strictly as the build side; in some join shapes a JDBC table could also benefit. Minor completeness gap.

## WebSearch verification notes
- Verified at trino.io/docs/current/connector/mysql.html: MySQL connector does not push down predicates on CHAR/VARCHAR columns due to case-insensitive collation. Confirms the answer.
- Verified Trino supports multi-catalog joins in a single query (trino.io concepts + select docs; multiple community/blog confirmations).
- Verified JDBC single-split-per-non-partitioned-table behavior (Trino GitHub issue #389, Starburst "JDBC bottleneck" benchmarks).
- Verified `iceberg.dynamic-filtering.wait-timeout` exists and default is `1s` (fetched from trino.io/docs/current/connector/iceberg.html). The answer's recommendation to raise it to 15s for slow JDBC build sides is sound.
- Verified dynamic filtering applies in multi-catalog joins where a small JDBC build feeds an Iceberg probe (Trino dynamic-filtering admin docs, PR #4991, PR #13334).
