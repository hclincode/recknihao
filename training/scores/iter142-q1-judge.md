# Iter142 Q1 — Judge Score

**Question topic**: Hive Metastore outage — what it is, what breaks, recovery, backup strategy
**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter142-q1.md`
**Production stack**: on-prem k8s, Trino 467, Iceberg 1.5.2, MinIO, Hive Metastore (RDBMS-backed), Debezium 2.x, Spark, JWT, OPA

---

## Score Breakdown

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All major claims verified against official docs and community sources. HMS is correctly described as a service backed by an RDBMS (Derby/MySQL/Postgres/Oracle/MSSQL per Apache Hive admin manual). Stateless service + active/active multi-instance pattern is the canonical Cloudera/Apache recommendation. Iceberg metadata.json/manifest-in-object-storage claim is correct: catalog only stores pointer to current metadata.json, then engines read the metadata tree directly from MinIO — meaning when metastore is back, all snapshot state is intact. Data-files-safe-in-MinIO claim is correct. Thrift client + retry/pool claim is consistent with Trino Iceberg connector's Thrift metastore implementation. Postgres HA via Patroni + etcd is the standard on-prem HA recipe. Minor nit: the example Spark config keys (`spark.sql.catalog.iceberg.pool.connection.*`) are illustrative rather than literal property names — the Iceberg Spark catalog actually uses `spark.sql.catalog.<name>.uri` plus Iceberg `HiveCatalog` Thrift settings; the principle (pooling + retry) is right but the exact key path is hand-waved. Not enough to drop below 5 given the rest is solid. |
| Beginner clarity | 5 | "Filing cabinet / phone book" analogy is excellent. Walks an actual lookup ("I'm looking for table analytics.user_events — where are its files?") so the engineer can picture the round-trip. Each section opens with the takeaway in plain English before any config detail. Jargon (Thrift, Parquet, manifest, RTO/RPO, WAL, PITR) is introduced with context the engineer can decode. The "phone book disappears, phone lines still working" image directly addresses the user's stated fear ("is our data actually safe"). |
| Practical applicability | 5 | Concrete, copy-pastable recovery playbook with timeboxes (first 5 min / 1–2 hr / 1–24 hr), a real `kubectl delete pod` command, validation SQL (`SHOW TABLES`, `SELECT COUNT(*)`), specific HA recipes for both PostgreSQL (Patroni + etcd, 3 replicas) and MySQL (Group Replication / Galera), and a clear separation of "what to back up" (the HMS schema tables: DBS, TBLS, COLUMNS, PARTITIONS, SDS) vs. "what NOT to rely on" (don't double-back-up MinIO). All advice fits the on-prem k8s stack (no AWS RDS, no Glue) per prod_info.md. The "pod redundancy alone is not enough — backing RDBMS must also be HA" warning is exactly right and is the most commonly missed gotcha in HMS HA. |
| Completeness | 5 | All four explicit sub-questions answered: (1) what HMS is, (2) what breaks (Trino, Spark, Debezium-via-Spark, dbt) and what keeps running (MinIO + direct Parquet readers), (3) recovery process (immediate / short / medium), (4) backup vs. data safety (data safe; backing DB is the only thing that matters for catalog state). Bonus coverage: RTO/RPO numbers, monitoring/alerting recommendations, and a postmortem checklist (out-of-disk, connection pool exhaustion, network partition). |

**Average = (5 + 5 + 5 + 5) / 4 = 5.00**

---

## What Was Verified Correct (via WebSearch)

1. **HMS = stateless service backed by RDBMS**: Confirmed by Apache Hive admin manual and Cloudera docs. HMS instances run active/active and share a single backend RDBMS (MySQL/Postgres/Oracle/MSSQL/Derby).
2. **Data in MinIO is safe during HMS outage**: Confirmed by Iceberg spec — the catalog (HMS in this case) only stores a pointer to the current metadata.json. Once HMS returns, engines re-read metadata directly from object storage, so no snapshot/schema/file-list state is lost.
3. **What breaks vs what keeps running**: Correct. Trino and Spark both depend on HMS for table resolution; MinIO continues serving objects independently. Direct-S3 readers that don't go through a catalog would keep working — accurately noted as theoretical for this stack.
4. **Pod-redundancy-alone-is-not-enough**: Verified. Multiple Cloudera and community docs explicitly call out that HMS HA requires both multiple HMS instances AND an HA backing database (replication + automatic failover). Single-node Postgres behind 3 HMS pods is the textbook anti-pattern.
5. **Recovery steps**: Operationally correct. Restarting HMS pods in k8s is the right first action when the backing DB is healthy; the validation SQL (`SHOW TABLES`, `SELECT COUNT(*)`) is the standard smoke test; failover-or-restore is the right fallback when the DB itself is down.
6. **Patroni + etcd recommendation**: Standard on-prem PostgreSQL HA stack, well-documented and widely deployed.
7. **HMS schema tables (DBS, TBLS, COLUMNS, PARTITIONS, SDS)**: Correct names per the open-source Hive Metastore DDL.

---

## Errors or Gaps Found

**Minor (not score-affecting):**

1. **Illustrative Spark config keys**: `spark.sql.catalog.iceberg.pool.connection.*` is gestural rather than a real property path. The actual knobs live in the Iceberg `HiveCatalog` configuration (e.g., `clients`, `client-pool-size`) and the underlying Thrift client. The directional advice (enable pooling + retry) is correct, but a more rigorous answer would name the actual properties or explicitly label the example as illustrative.
2. **Debezium phrasing**: The answer says "Debezium 2.x in streaming mode writes changes via Spark Structured Streaming." In many setups Debezium writes directly to Kafka and a separate Spark/Flink job lands the data in Iceberg. The HMS dependency is correctly attributed to the Spark-to-Iceberg leg, but the wording could be misread as Debezium itself calling Spark.
3. **RPO claim**: "RPO < 1 hour from regular backups" in the bottom line is slightly looser than the body, which correctly says < 1 second with streaming replication or up to 6–12 hours with periodic backups. Not wrong, just less precise than the body.

None of these warrant a score deduction given the depth and correctness of the rest of the answer.

---

## Resource Fix Recommendations

**LOW priority — nice to have for future iterations:**

- Add a small subsection to the relevant maintenance/ops resource (likely `resources/19-iceberg-maintenance.md` or wherever HMS is covered) naming the actual Iceberg `HiveCatalog` pooling properties (`clients`, `client-pool-size`, `client-pool-cache-eviction-interval-ms`) so future answers can give literal config keys instead of illustrative ones.
- Optional: a short note distinguishing Debezium-direct-to-Kafka-then-Spark-to-Iceberg from Debezium-via-Spark-Structured-Streaming, since the HMS dependency point lands in different parts of the pipeline.

---

## Verdict

**PASS** (avg 5.00 ≥ 4.5 threshold)

This is a model answer for an operational/SRE question on an on-prem lakehouse stack. It correctly distinguishes the catalog layer (recoverable via HA + backups) from the data layer (safe by virtue of object storage), gives a real recovery runbook with commands and validation SQL, and calls out the most common HMS HA anti-pattern (single backing DB behind redundant pods). Fits the prod_info.md stack tightly (on-prem k8s, MinIO, Trino 467, Iceberg 1.5.2, Spark, Debezium) and avoids cloud-only recommendations.

Sources used for verification:
- [Apache Hive AdminManual Metastore Administration](https://hive.apache.org/docs/latest/admin/adminmanual-metastore-administration/)
- [Cloudera — Introduction to Hive metastore](https://docs.cloudera.com/cdp-private-cloud-base/7.3.1/hive-hms-overview/topics/hive-hms-introduction.html)
- [Trino 481 — Metastores docs](https://trino.io/docs/current/object-storage/metastores.html)
- [Trino 481 — Iceberg connector](https://trino.io/docs/current/connector/iceberg.html)
- [Apache Iceberg Spec](https://iceberg.apache.org/spec/)
- [Patroni docs (PostgreSQL HA)](https://patroni.readthedocs.io/en/latest/ha_multi_dc.html)
- [Setting Up Hive Metastore for High Availability — Reintech](https://reintech.io/blog/setting-up-hive-metastore-high-availability)
