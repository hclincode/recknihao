# Judge Feedback — Iter 401 (Extended Phase)

**Result**: 4.59375 STRONG PASS — recovery from iter400 3.8125 FAIL

## Per-question scores

### Q1 — Complete dbt-trino Iceberg incremental model config
**4.6875 STRONG PASS** (TA 4.75, BC 4.5, PA 5.0, Comp 4.5)

Iter400's dbt-trino YAML-missing gap is now closed. All four iter400 gotchas have concrete config syntax:
- `incremental_strategy='merge'` (resolves append-default footgun)
- `on_schema_change='append_new_columns'` (resolves silent-data-loss footgun)
- `unique_key` (resolves merge-degrades-to-append footgun)
- `partitioned_by` (resolves missing partition-spec footgun)

Watermark filter with `COALESCE(MAX(watermark_col), DATE '1970-01-01')` is the production-correct first-run-seed pattern. 4-day lookback is a concrete tunable number. Compiled MERGE SQL shown is the highest-value addition — beginner sees what the YAML actually compiles to and can debug from there.

**Remaining gap**: maintenance schedule was "mentioned" but post_hooks literal snippet (`post_hooks=["ALTER TABLE {{ this }} EXECUTE optimize", "ALTER TABLE {{ this }} EXECUTE expire_snapshots(retention_threshold => '7d')"]`) not fully spelled out. Iter400 action #2 partially landed.

### Q2 — Predicate pushdown verification via EXPLAIN
**4.5 STRONG PASS** (TA 4.75, BC 4.0, PA 4.75, Comp 4.5)

Three-layer verification stack is the correct production diagnosis approach:
1. Plan-level: `EXPLAIN (TYPE DISTRIBUTED)` — `constraint = ...` attribute under `TableScan` (pushed) vs separate `ScanFilterProject` above `TableScan` (not pushed)
2. Runtime-level: `EXPLAIN ANALYZE` Input rows vs Output rows ratio (1:1 = pushdown, 100:1 = full scan + Trino-side filter)
3. Source-level: Postgres slow query log — closes the loop because plan-only can lie if JDBC layer rewrites

The Postgres slow log as ground truth is excellent — it's the only end-to-end confirmation that pushdown reached the source DB.

**Remaining gaps**:
- No literal EXPLAIN output text snippet beginner can pattern-match against
- No mention of `pushdownFilters` / `aggregation-pushdown.enabled` connector config check
- No warning about predicate types unpushable by design (LIKE with leading wildcard, function-on-column)
- No `pg_stat_statements` mention as alternative to slow query log

## Topic score updates

| Topic | Before | After | Delta |
|---|---|---|---|
| Postgres-to-Iceberg ingestion | 4.4877 / 143 | 4.4891 / 144 | +0.0014 (Q1 PASSED) |
| Trino federation / cross-source connectors | 4.4925 / 265 | 4.4925 / 266 | flat at threshold floor (Q2 PASSED) |
| SQL query best practices for OLAP (EXPLAIN verification) | 4.6121 / 21 | 4.6070 / 22 | -0.0051 (Q2 PASSED but below running avg) |

## Pattern observation iter392-401

10-iter window: 4.75 / 4.125 / 3.9375F / 4.625 / 4.75 / 3.125F / 4.3125 / 4.375 / 4.34375 / 4.09375 / 4.0625 / 3.8125F / **4.59375P**

Recovery iteration. Teacher's iter401 HIGH actions (dbt-trino canonical YAML + post-hook maintenance) both landed in Q1 — two-thirds of iter400 carry-forward closed in one cycle. Q2 predicate pushdown three-layer verification stack is exactly what the federation topic needed.

## Teacher actions next (iter402)

1. **LOW** — complete iter400 post-hook carry-forward: literal `post_hooks=["ALTER TABLE {{ this }} EXECUTE optimize", "ALTER TABLE {{ this }} EXECUTE expire_snapshots(retention_threshold => '7d')"]` snippet in dbt-trino resource
2. **LOW** — add EXPLAIN output text snippets to predicate-pushdown resource showing literal `TableScan[table=postgresql:public.events, constraint = ...]` vs `ScanFilterProject[...]\n  - TableScan[...]` so beginners can pattern-match against actual Trino output
3. **LOW** — add `pushdownFilters` / `aggregation-pushdown.enabled` connector config check + unpushable predicate type warnings (LIKE leading wildcard, function-on-column) to predicate pushdown resource

## Judge probe targets next (iter402)

1. **2nd-angle dbt-trino merge** — "my incremental merge model is producing duplicates — what to check" probes unique_key + strategy=append default (carry from iter400 backlog)
2. **2nd-angle predicate pushdown** — "I confirmed pushdown via EXPLAIN but Postgres slow log shows full table scan — what's happening" probes JDBC query rewrite + unpushable predicate types
3. **CoW vs MoR 3rd-angle** — "MERGE INTO rewriting 80GB per run on 200GB table — how to switch to row-level deletes" probes `write.merge.mode=merge-on-read` (carry from iter400)
4. Carry-forward standing backlog: write.isolation-level 2nd-angle, SHOW SESSION/catalog-prefix 2nd-angle, HMS->Nessie no-downtime, SPILL_FAILED 60GB at 200GB cap, MERGE INTO rollback, OPA-override timeout, schema registry compat, EXPLAIN TYPE IO + VALIDATE, result caching 2nd-angle, Iceberg branches fast_forward 2nd-angle, JWT+OPA concurrency, partition spec migration + rewrite_data_files, Iceberg tagging 3rd-angle, fs.cache 3rd-angle JMX, bucket(tenant_id) high-cardinality 2nd-angle, PERCENT_RANK/NTILE 3rd-angle, RANGE INTERVAL gap-day semantics
