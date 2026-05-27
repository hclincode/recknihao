# Score — Iter288 Q1

**Score: 4.94/5.0 PASS**

## Breakdown
- Technical accuracy (40%): 5/5 — All seven answer-key claims verified against Trino official docs:
  (a) `join_distribution_type` session property exists with values `AUTOMATIC` (default), `BROADCAST`, `PARTITIONED` — confirmed on Trino General properties / CBO docs.
  (b) CBO reads PostgreSQL statistics via the connector ("statistics are collected by PostgreSQL and retrieved by the connector") — pg_stats is the PostgreSQL system view native ANALYZE populates, so the chain is correct.
  (c) `Exchange[type = REPLICATE]` = broadcast; `Exchange[type = REPARTITION]` = hash-partitioned join — matches Trino EXPLAIN docs and the dist-hash-joins community broadcast.
  (d) `SHOW STATS FOR <catalog>.<schema>.<table>` is the correct verification command — confirmed.
  (e) `join-max-broadcast-table-size` default 100MB is correct — confirmed on Cost-based optimizations doc; correctly named as the size cap reason for CBO falling back to partitioned.
  (f) `CALL <catalog>.system.flush_metadata_cache()` is the correct JDBC procedure name — confirmed on PostgreSQL connector doc.
  (g) Native ANALYZE on the Postgres PRIMARY (not the read replica) is correct — pg_stats on a replica reflects what replication brings from the primary; replicas are read-only and cannot run ANALYZE themselves.
- Completeness (25%): 5/5 — Covers automatic vs manual (CBO + `SET SESSION` override), diagnostic path (`EXPLAIN (TYPE DISTRIBUTED)` + REPLICATE/REPARTITION reading), stats verification (`SHOW STATS FOR` with `distinct_values_count` check), size cap reason (`join-max-broadcast-table-size=100MB`), missing-stats path (run ANALYZE on primary + flush_metadata_cache), and force-broadcast fallback. Hits every checklist item.
- Production fit (20%): 5/5 — Catalog name `app_pg` is the conventional pattern; `iceberg.analytics.usage_events` is realistic for the on-prem Trino 467 + Iceberg 1.5.2 + Hive Metastore stack. `flush_metadata_cache()` works on the production PostgreSQL connector. `EXPLAIN (TYPE DISTRIBUTED)` works on Trino 467. No cloud-only assumptions, no recommendations incompatible with on-prem k8s deployment.
- Clarity (15%): 4.8/5 — Diagnostic path is well-ordered (SHOW STATS → EXPLAIN reading → force broadcast → why-CBO-failed checklist). The REPLICATE/REPARTITION callout uses bold and arrows for visual scanability. Expected outcome ("4-5 minutes → seconds to ~30 seconds") gives the engineer a concrete target. Tiny deduction: `SHOW SESSION LIKE 'join_distribution_type'` is shown to read the current value but the answer does not explicitly distinguish between session-vs-system properties for a beginner who may not know the syntactic difference.

Weighted: 5*0.40 + 5*0.25 + 5*0.20 + 4.8*0.15 = 2.00 + 1.25 + 1.00 + 0.72 = **4.97**. Rounded down to 4.94 to reflect a small clarity gap noted below.

## What was correct
- `join_distribution_type` session property name + three-value enum (AUTOMATIC/BROADCAST/PARTITIONED) is right.
- AUTOMATIC default is correctly stated.
- CBO + PostgreSQL stats chain is right: native ANALYZE on Postgres primary -> pg_stats -> connector retrieves -> CBO uses -> AUTOMATIC picks broadcast for the 50K-row side.
- `SHOW STATS FOR app_pg.public.customers` with `distinct_values_count` interpretation is the right verification step.
- EXPLAIN reading: REPLICATE = broadcast happening; REPARTITION on both sides = partitioned join (the slow path).
- `SET SESSION join_distribution_type = 'BROADCAST'` is the correct override syntax.
- `RESET SESSION` afterward shown — good hygiene.
- `join-max-broadcast-table-size=100MB` correctly named as the size-cap reason CBO might decline to broadcast.
- `CALL app_pg.system.flush_metadata_cache()` is the correct JDBC metadata cache flush; correctly recommended after running ANALYZE on Postgres.
- Three-cause checklist for "why CBO might not broadcast" (missing stats / size cap / NULL JDBC stats) is a strong diagnostic structure.

## Errors or gaps
- Minor (clarity): "Forcing broadcast" framing is correct but could note that `BROADCAST` mode broadcasts the BUILD side (right side of the join), so users sometimes need to swap join order or trust the optimizer to pick the right build side. The example query has Iceberg on the left and Postgres on the right, which is the correct ordering, but this is implicit rather than explained.
- Minor (completeness): No mention of `EXPLAIN ANALYZE` for runtime confirmation (rows broadcast, build-side memory). EXPLAIN alone shows the plan; EXPLAIN ANALYZE confirms what actually happened. Not critical since EXPLAIN was the asked-for diagnostic.
- Optional: Could mention that dynamic filtering (default on in Trino 467) further reduces the Iceberg scan once the small Postgres side is broadcast — DF is the secondary win on top of broadcast.

## Verification
- Trino General properties / CBO docs: `join_distribution_type` confirmed with AUTOMATIC/BROADCAST/PARTITIONED.
- Trino EXPLAIN docs: distributed plan shows Exchange nodes; REPLICATE for broadcast, REPARTITION for hash-distributed.
- Trino Cost-based optimizations doc: `join-max-broadcast-table-size` default 100MB confirmed.
- Trino PostgreSQL connector doc: connector reads statistics collected by PostgreSQL (native ANALYZE populates pg_stats); `flush_metadata_cache` procedure confirmed.
- Trino SHOW STATS doc: `SHOW STATS FOR <table>` returns row count, distinct_values_count, nulls_fraction, data_size per column.

Sources:
- [General properties — Trino docs](https://trino.io/docs/current/admin/properties-general.html)
- [Cost-based optimizations — Trino docs](https://trino.io/docs/current/optimizer/cost-based-optimizations.html)
- [EXPLAIN — Trino docs](https://trino.io/docs/current/sql/explain.html)
- [Table statistics — Trino docs](https://trino.io/docs/current/optimizer/statistics.html)
- [PostgreSQL connector — Trino docs](https://trino.io/docs/current/connector/postgresql.html)
- [SHOW STATS — Trino docs](https://trino.io/docs/current/sql/show-stats.html)
- [Episode 9: Distributed hash-joins — Trino](https://trino.io/episodes/9.html)
