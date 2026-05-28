# Judge Feedback — Iter 357 Q1

## Question recap

SaaS engineer asks: should we keep federating a 50M-row Postgres `customers` table live (via the Trino postgresql connector) for joins with our Iceberg `events` table, or copy/materialize it into Iceberg? What are the tradeoffs?

This is the RE-PROBE that iter356 explicitly requested (judge probe target #3): test whether iter357 teacher actions #3/#5 (federate-vs-ingest decision matrix) landed in resources.

## Score

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 4.0 | Core mechanics correct; specific numbers unsourced; key levers (dynamic filtering, `join_distribution_type=PARTITIONED`) absent |
| Beginner clarity | 4.0 | Plain-language framing; multiple unexplained terms |
| Practical applicability | 4.5 | Concrete, pasteable; stack fit incomplete (dbt, CDC, k8s specifics) |
| Completeness | 3.5 | Binary >5M cutoff loses the gradient; CDC tier missing; stop-gap tier missing |
| **Average** | **4.00** | **PASS** (soft — right at the per-question 4.0 bar) |

**Topic running avg**: 4.511 -> **4.509** across 254 questions. PASSED (still above 4.5 threshold but downward smoothing).

## What landed (teacher action follow-through)

The iter357 teacher action #3 was: "add an explicit 'when to federate live vs ingest into Iceberg' decision matrix." Responder DID surface federate-vs-ingest as the architectural alternative — this was the iter356 critical gap. Big improvement vs iter356 Q1 which never mentioned ingestion at all.

The iter357 teacher action #5 (decision matrix) PARTIALLY landed — the matrix was reduced to a binary `>5M=ingest` rule instead of the documented three-tier gradient.

## What did not land

1. **Gradient was flattened.** Iter357 teacher action documented:
   - `<10M` -> federate live with `join_distribution_type=PARTITIONED`
   - `10M-100M` -> ingest nightly via `INSERT INTO ... SELECT * FROM postgres_catalog.<schema>.<table>`
   - `>100M` -> CDC pipeline (Debezium -> Iceberg)

   Responder collapsed this to `>5M -> ingest`. The CDC tier is missing — important because the engineer said "every dashboard query," which implies the data freshness floor matters and CDC with 1–5 min lag is often the right answer for high-traffic dashboards.

2. **Dynamic filtering still absent** (recurring gap flagged iter164/165/356/357 — slipped AGAIN). For Iceberg-fact x JDBC-dimension joins, dynamic filtering is the single biggest lever Trino has. The answer says "queries run in <500ms" after cutover without naming the mechanism. This is the THIRD consecutive iteration where the federation answer omits dynamic filtering — needs to be a checklist item in `resources/22`.

3. **`join_distribution_type=PARTITIONED` stop-gap absent.** Engineer is currently in pain. Ingestion takes time to build. The stop-gap order (dynamic filtering check -> `ANALYZE` on Postgres source -> `SET SESSION join_distribution_type='PARTITIONED'` -> consider `spill_enabled=true`) buys runway while the ingestion pipeline is built. Not surfaced.

4. **Production stack specifics absent.** prod_info.md says dbt is permitted, Spark runs on k8s, MinIO is the Iceberg storage layer. None of these are named. The answer says "Spark job runs once per night" with no mention of how it runs on this stack (SparkApplication CR on k8s). dbt would be the natural tool for the 15-min micro-batch path with `incremental` materialization.

5. **Specific unsourced numbers.** "5M rows," "<500ms," ">70% CPU" are presented as factual without basis. The 100MB `join_max_broadcast_table_size` default is sourced. Specific perf numbers should either cite a source or be removed.

6. **Beginner clarity terms unexplained.** "build side", "JDBC", "dynamic filtering", "min/max statistics", "partition pruning", "columnar" all appear without inline definitions. This is the same recurring gap iter356 flagged.

## Pattern across federation answers (iter356 -> iter357)

- Iter356 Q1 (4.125): missed federate-vs-ingest entirely — never surfaced ingestion as the architectural alternative.
- Iter357 Q1 (4.00): surfaced ingestion correctly — BIG win — but flattened the gradient, omitted dynamic filtering AGAIN, omitted stop-gap tuning, omitted prod-stack fit.

Trajectory is positive on the architectural framing but the federation runbook is still incomplete on its core levers (dynamic filtering, partitioned distribution) and on prod-environment fit (dbt, CDC, k8s, MinIO).

## ITER358 TEACHER ACTIONS

**MEDIUM (Q1 passed soft, topic stable but slipping):**

1. **Restore the three-tier gradient in `resources/22-trino-federation-postgresql.md`.** Make the decision tree unambiguous: <10M federate live with PARTITIONED + dynamic filtering / 10M-100M ingest nightly Spark+dbt / >100M or <5min freshness SLO -> Debezium CDC -> Iceberg MoR. Show example syntax for each tier.

2. **Add a "stop-gap before you commit to ingestion" tier** — engineer in pain TODAY who needs to ship the cutover in 2 weeks. Order: (a) verify `join-dynamic-filtering-enabled=true`; (b) `SHOW STATS FOR postgres_catalog.<schema>.<table>` -> `ANALYZE <table>` on Postgres source if row_count NULL; (c) `SET SESSION join_distribution_type='PARTITIONED'`; (d) consider `spill_enabled=true` for stability. This is the bridge the answer is missing.

3. **Add inline definitions for federation jargon** — "build side", "JDBC", "dynamic filtering", "columnar storage", "min/max statistics", "partition pruning". These keep being used without explanation across multiple iterations. Add a one-line glossary at the top of `resources/22`.

4. **Add a cutover playbook** — full refresh vs incremental MERGE with primary key, snapshot atomicity, dual-write window vs cut-and-replace, row-count and aggregate verification against the Postgres source.

5. **Tie examples to the production stack** — Spark job runs as `SparkApplication` CR on k8s; dbt model uses `incremental` with `unique_key='customer_id'`; MinIO is the S3 backend; Iceberg catalog is Hive Metastore. This makes the advice actionable on the engineer's actual environment.

## ITER358 JUDGE PROBE TARGETS

Still-open / under-tested topics:

1. **CDC-vs-batch ingestion** — re-probe at "we need fresher data than nightly batch — what's the architecture for syncing Postgres customers into Iceberg every 5 minutes?" Tests if teacher action #1 (CDC tier) lands.
2. **Stop-gap federation tuning** — re-probe at "we can't ingest yet (cutover takes 2 weeks) — what session properties do we set to keep dashboards alive in the meantime?" Tests if teacher action #2 (stop-gap tier) lands.
3. **Query plan optimization (EXPLAIN ANALYZE reading)** — never probed; recurring rubric note since iter356.
4. **Cost considerations cloud vs on-prem** (S3+Athena+Glue lift-and-shift vs on-prem Trino+Iceberg+MinIO) — never probed.

## Sources verified via WebSearch

- [PostgreSQL connector — Trino 481 Documentation](https://trino.io/docs/current/connector/postgresql.html)
- [Cost-based optimizations — Trino 481 Documentation](https://trino.io/docs/current/optimizer/cost-based-optimizations.html) — `join_max_broadcast_table_size`, broadcast right-side memory requirement
- [Dynamic filtering — Trino 481 Documentation](https://trino.io/docs/current/admin/dynamic-filtering.html)
- [General properties — Trino 481 Documentation](https://trino.io/docs/current/admin/properties-general.html) — `join_distribution_type`
- [Benchmarking the JDBC Bottleneck in Trino — Starburst](https://www.starburst.io/blog/benchmarking-the-jdbc-bottleneck-in-trino/) — JDBC serialization bottleneck

## Iter 357 End-of-Iteration Summary

### Per-question scores

| Question | Topic | Score | Verdict |
|---|---|---|---|
| Q1 | Trino federation: federate-vs-ingest 50M-row Postgres customers x Iceberg events | 4.00 | soft PASS |
| Q2 | When to add OLAP: 5M-row Postgres at 45s p95, prod already runs Trino+Iceberg+MinIO — proxy test + decision | 4.00 | soft PASS |
| **Iter 357 average** | | **4.00** | **MARGINAL PASS** |

### Root causes — what improved, what slipped

**What landed (teacher actions from iter356 -> iter357):**
- Q1: federate-vs-ingest now surfaced as the architectural alternative (iter356 critical miss is closed). Big win on architectural framing.
- Q2: Postgres CSV extraction syntax fix landed — no more `INTO OUTFILE` mistakes; `\COPY ... TO ...` / `COPY ... TO ...` is now correct. Critical iter356 FAIL on Q2 is closed.
- Q2: "use the OLAP engine you already have" callout partially landed — Trino+Iceberg+MinIO is now mentioned as the proxy path instead of defaulting to a DuckDB install.

**What did not land (regressions / recurring gaps):**
1. **Dynamic filtering omitted on federation answer for the 3rd consecutive iteration** (iter164/165, iter356, iter357). This is now a chronic gap — the answer claims "<500ms after cutover" without naming the single biggest Trino lever for fact x dim joins. Must become a CHECKLIST ITEM in resources/22, not just prose.
2. **Three-tier federate-vs-ingest gradient flattened to a binary `>5M=ingest`.** The CDC tier (>100M or <5min freshness SLO -> Debezium -> Iceberg MoR) was documented in iter357 teacher actions but did not survive into the answer. CDC is the right answer for "every dashboard query" freshness — losing this tier loses the high-traffic dashboard case entirely.
3. **Stop-gap tuning tier missing on Q1.** Engineer is in pain TODAY and ingestion takes weeks to build. The bridge order (dynamic filtering check -> `ANALYZE` Postgres source -> `SET SESSION join_distribution_type='PARTITIONED'` -> `spill_enabled=true`) was not surfaced.
4. **Tuning-first framing on Postgres-vs-OLAP subtopic still weak.** Q2 at 4.00 means the third probe of this subtopic (iter355 4.9375 / iter356 3.875 / iter357 4.00) shows MIXED durability — the subtopic is NOT yet stable. The answer routes to Trino+Iceberg proxy correctly but is still light on `EXPLAIN (ANALYZE, BUFFERS)`, index audit (`pg_stat_user_indexes`), `work_mem`, partial indexes, BRIN, MVs, `max_parallel_workers_per_gather` BEFORE the OLAP push recommendation.
5. **Production-stack fit still partial.** dbt is rarely named where it's the natural tool (incremental materialization for nightly/15-min batch). SparkApplication CR on k8s for the ingestion job is missing. MinIO / Hive Metastore catalog plumbing rarely surfaces concretely.
6. **Beginner clarity terms repeatedly unexplained.** "build side", "JDBC", "dynamic filtering", "min/max statistics", "partition pruning", "columnar", "REPLICATE", "REPARTITION", "hash-redistributes" keep appearing without inline definitions across multiple iterations. Needs a one-line glossary at the top of resources/22.

### Iter 358 teacher actions

**HIGH (chronic gaps blocking strong pass):**
1. **Promote dynamic filtering to a TOP-of-section checklist item in resources/22-trino-federation-postgresql.md.** Not buried in prose. Show: `SET SESSION join-dynamic-filtering-enabled = true` (verify cluster default), `EXPLAIN (ANALYZE, VERBOSE)` reading the `Dynamic filters` line, expected rows-filtered ratio for Iceberg-fact x JDBC-dim joins. This has slipped 3 iterations in a row.
2. **Restore the three-tier federate-vs-ingest gradient with the CDC tier intact.** Decision tree must be unambiguous: `<10M federate live` (PARTITIONED + dynamic filtering) / `10M-100M ingest nightly` (Spark+dbt incremental) / `>100M or <5min freshness SLO -> Debezium CDC -> Iceberg MoR`. Show working syntax per tier. Do not let the answer collapse this to a binary cutoff.
3. **Add the "stop-gap before you commit to ingestion" tier.** Order: (a) verify `join-dynamic-filtering-enabled=true`; (b) `SHOW STATS FOR postgres_catalog.<schema>.<table>` -> `ANALYZE <table>` on Postgres source if `row_count` NULL; (c) `SET SESSION join_distribution_type='PARTITIONED'`; (d) `SET SESSION spill_enabled=true` for stability. This is the runway-buying bridge.

**MEDIUM (subtopic durability):**
4. **Reinforce tuning-first framing for sub-10M-row Postgres slowness** BEFORE the OLAP-proxy step. Concrete pre-OLAP checklist: `EXPLAIN (ANALYZE, BUFFERS)`, `pg_stat_user_indexes` audit, `work_mem` sizing, partial indexes on hot filter predicates, BRIN for time-series, materialized views, `max_parallel_workers_per_gather`. The OLAP proxy is the SECOND step, not the first.
5. **Tie examples to the production stack concretely.** Spark ingest = `SparkApplication` CR on k8s. dbt = `incremental` materialization with `unique_key='customer_id'`. MinIO = S3 backend for the Iceberg warehouse. Hive Metastore = Iceberg catalog. Name these by name in code samples.
6. **Add inline definitions / one-line glossary** for "build side", "JDBC", "dynamic filtering", "columnar storage", "min/max statistics", "partition pruning", "REPLICATE", "REPARTITION", "hash-redistributes" at the top of resources/22.

**LOW (cutover playbook):**
7. **Add a federation -> Iceberg cutover playbook** — full refresh vs incremental MERGE with primary key, snapshot atomicity, dual-write window vs cut-and-replace, row-count and aggregate verification against the Postgres source.

### Iter 358 judge probe targets

Still-open / under-tested topics:
1. **CDC tier re-probe** — "we need fresher data than nightly batch — what's the architecture for syncing Postgres customers into Iceberg every 5 minutes?" Tests if action #2 (CDC tier) survives into the answer.
2. **Stop-gap federation tuning re-probe** — "we can't ingest yet (cutover takes 2 weeks) — what session properties do we set to keep dashboards alive in the meantime?" Tests if action #3 (stop-gap tier) lands.
3. **Postgres-vs-OLAP decision — 4th probe** — three probes (4.9375 / 3.875 / 4.00) show mixed durability; needs a 4th probe at a different phrasing (e.g., "5M rows, 12s p95, fits in RAM — do we even need OLAP?") before declaring stable.
4. **Query plan optimization (EXPLAIN ANALYZE reading)** — never probed, recurring rubric note since iter356.
5. **Cost considerations cloud vs on-prem** (AWS S3+Athena+Glue lift-and-shift vs on-prem Trino+Iceberg+MinIO) — never probed.

