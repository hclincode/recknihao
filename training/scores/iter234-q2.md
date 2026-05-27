# Iter 234 Q2 Score

**Score: 4.50 / 5.0**
**Pass: YES** (threshold is 4.5 in extended/final phase)

## What was correct

- **One-split limitation for OSS Trino MySQL connector** — accurate. JDBC-based connectors in OSS Trino emit a single split per non-partitioned table scan, serializing the read on one worker thread. Verified against Starburst's "JDBC bottleneck" benchmarking posts and trinodb/trino#389.
- **`partition-column` not available in OSS Trino** — correct. Parallel JDBC partitioning is a Starburst Enterprise feature; OSS docs do not expose `partition-column` / `numPartitions` for the MySQL connector.
- **Adding workers does not help** — correct corollary of the single-split fact.
- **Predicate pushdown as #1 tuning lever and the `EXPLAIN (TYPE DISTRIBUTED)` Filter-above-TableScan diagnostic** — accurate and actionable.
- **Dynamic filtering direction** (probe side receives an IN-list derived from the build side) — correctly described conceptually.
- **`metadata.cache-ttl=30s`** — sensible default; OSS default is `0s` (disabled) so setting any reasonable non-zero value is an improvement. 30s is a reasonable conservative pick.
- **JDBC throughput ballpark (50K-200K rows/sec single-threaded)** — within the right order of magnitude.
- **Decision framework with multi-signal threshold** (size, latency, frequency, join complexity) — practical and aligned with industry practice; the 5M-row trigger is reasonable given OSS Trino's single-split reality.
- **Ingest path on the prod stack** (Spark→MinIO→Iceberg via HMS, Airflow/cron) — fits the documented on-prem k8s + MinIO + Iceberg 1.5.2 + HMS environment.
- **Cross-catalog consistency caveat** (Iceberg snapshot vs MySQL READ COMMITTED) and non-transactional write semantics — correct and useful framing.
- **Concrete next steps section** — gives the engineer a clear runbook (EXPLAIN, COUNT timing, snapshot job, shadow validation).

## What was wrong or missing

- **Dynamic filtering wait-timeout attribution is slightly misdirected.** The answer says to bump `dynamic-filtering.wait-timeout` in the **Iceberg** catalog properties (default 1s) for the scenario where MySQL is the probe receiving the IN-list. In a MySQL-probe / Iceberg-build join, the relevant wait-timeout is on the **MySQL** connector (already defaults to 20s in OSS Trino), not the Iceberg one. This is the same Iceberg-vs-JDBC wait-timeout disambiguation called out in the iter164 Q1 feedback, and the answer still gets it half-tangled. Minor but it is the kind of mis-instruction that wastes a tuning afternoon.
- **No mention of OPA on the production stack** for governing whether the snapshot/ingest job is permitted to write to the Iceberg catalog. Several recent topic feedbacks have asked for OPA framing on write actions.
- **No mention of session properties** (e.g., `<catalog>.dynamic_filtering_wait_timeout`) as a per-query alternative to editing catalog properties files — useful for an engineer who wants to test without a Trino restart.
- **JDBC `connection-url` parameters** like `?useCursorFetch=true&defaultFetchSize=...` are not mentioned as a marginal-but-real lever for the MySQL connector. The answer correctly says JDBC throughput is the bottleneck but doesn't list the small dials that *can* nudge it.
- **CDC alternative not mentioned.** The "copy MySQL into Iceberg" framing only covers periodic full snapshots; for a customers table at 10M+ rows, incremental/CDC (Debezium → Iceberg) is the more common pattern at scale and was not surfaced.
- **dbt is in the prod stack** and could be the natural home for the snapshot job orchestration (dbt snapshots) but is not mentioned.

## Verification notes

WebSearch and WebFetch against official trino.io docs and Starburst posts confirmed:

1. **OSS Trino MySQL connector emits one split per non-partitioned table scan.** Confirmed via trinodb/trino#389 ("Parallel read in jdbc-based connectors", still open) and Starburst's "The dangers of the JDBC bottleneck in Trino" / "Benchmarking the JDBC bottleneck" posts.
2. **`partition-column` is a Starburst Enterprise feature**, not in OSS Trino 467. The OSS MySQL connector docs page at trino.io/docs/current/connector/mysql.html does not document any partition-column or numPartitions property.
3. **`dynamic-filtering.wait-timeout` defaults differ by connector**:
   - Iceberg connector: **1s** (`iceberg.dynamic-filtering.wait-timeout`)
   - MySQL connector: **20s** (`dynamic-filtering.wait-timeout`)
   - The answer's recommendation to "make sure Iceberg's is at least 20s" is technically reasonable as a tuning step but is aimed at the wrong side of the join given the answer's own framing (MySQL is the probe in that example).
4. **`metadata.cache-ttl` default is 0s (disabled)**; any non-zero recommendation is an improvement. 30s is reasonable.
5. **JDBC throughput numbers** (50K-200K rows/sec) are consistent with Starburst's benchmark posts citing ~36-37 MB/s per JDBC connection.

## Recommendation for teacher

- **HIGH (correctness)** — `resources/22-trino-federation-postgresql.md` (or a MySQL sibling resource): add a "dynamic filtering: which side's wait-timeout do I tune?" callout. Rule: **tune the wait-timeout on the probe-side connector** (the side receiving the IN-list). Tabulate the connector defaults: Iceberg 1s, MySQL/Postgres 20s. The probe-side framing keeps answers from putting the recommendation on the wrong catalog.
- **MEDIUM (completeness)** — Add a CDC/incremental ingestion alternative to the "copy MySQL into Iceberg" decision tree. For a 10M+ row customers table, full snapshot hourly is wasteful; Debezium → Iceberg or a Spark MERGE INTO incremental pattern (using an `updated_at` watermark) belongs in the answer.
- **MEDIUM (production fit)** — Add an OPA write-permission note: the snapshot job's Spark identity must be allowed by OPA to write to the target Iceberg schema; this is a real prod gotcha for the on-prem k8s stack.
- **LOW (clarity)** — Mention session properties (`SET SESSION <catalog>.dynamic_filtering_wait_timeout = '30s'`) as the no-restart way to A/B test wait-timeout changes before editing the catalog properties file.
- **LOW (completeness)** — Brief mention of dbt snapshots as the natural orchestration vehicle for the periodic MySQL→Iceberg refresh in this stack.
