# Score: iter237-q2 — Federation Observability

**Score: 3.55 / 5.0**

## What was correct

- **EXPLAIN ANALYZE VERBOSE** is correctly identified as the primary per-operator diagnostic tool in Trino. The description that it executes the query and surfaces per-operator timing and metadata is accurate.
- **`dynamicFilterSplitsProcessed`** is a real, documented metric in EXPLAIN ANALYZE VERBOSE output. The interpretation (non-zero = dynamic filter fired, zero with `dynamicFilters = {...}` in plan = DF timed out) is correct. Confirmed via Trino PR #3217 and the EXPLAIN ANALYZE docs.
- **`system.runtime.queries`** is a real Trino system table. The column names (`query_id`, `user`, `state`, `created`, `source`, `queued_time_ms`, `analysis_time_ms`, `planning_time_ms`) are accurate.
- **Double-quoting `"user"`** is correct — `user` is a reserved keyword in Trino SQL.
- The **Web UI URL pattern** (`/ui/query.html?<query_id>`) and recommendation to use it for visual operator timeline is accurate and a good practical hint.
- The **Physical Input vs. expected rows** diagnostic for predicate pushdown is sound and actionable.
- The **decision tree** with three concrete scenarios (PostgreSQL-dominated, Iceberg-dominated, join-dominated) is well-structured and practically useful.
- The **`join_distribution_type = 'BROADCAST'`** recommendation for small dimensions on the build side is correct.
- The recommendation to **start with plain EXPLAIN before EXPLAIN ANALYZE VERBOSE** (to avoid the 30-40s re-execution cost twice) is a thoughtful workflow improvement.
- Warning about **`date_trunc()` wrapping breaking partition pruning** is a real, valuable nuance.

## What was wrong or missing

### CRITICAL: Wrong catalog for `dynamic-filtering.wait-timeout`

The answer recommends setting `dynamic-filtering.wait-timeout = 45s` in `etc/catalog/app_pg.properties` (the PostgreSQL catalog). **This is incorrect for the described topology.**

- In this scenario, **Iceberg events table = probe side (large)**, **PostgreSQL accounts table = build side (smaller)**.
- The `dynamic-filtering.wait-timeout` is a property of the **probe-side connector** — it controls how long the probe side waits for the build-side dynamic filter to arrive before generating splits.
- The Iceberg connector exposes `iceberg.dynamic-filtering.wait-timeout` (default 1s). It is set in the Iceberg catalog properties file, **not** in the PostgreSQL JDBC catalog.
- Setting `dynamic-filtering.wait-timeout` in the PostgreSQL catalog has no effect on whether Iceberg's split generation waits for the DF, because PostgreSQL is on the build side here and is not the entity doing split generation that needs to wait.
- The fix should be: set `dynamic-filtering.wait-timeout = 45s` in `etc/catalog/iceberg.properties` (or whatever the Iceberg catalog file is named).

This is a high-impact misdirection — the engineer would edit the wrong properties file, restart Trino, and observe no change.

### Overly broad VARCHAR pushdown claim

The answer says: "Check whether the column is VARCHAR — VARCHAR predicates do NOT push down on the PostgreSQL connector."

This is incorrect as stated. Per the official Trino PostgreSQL connector docs:
- **Equality predicates** (`=`, `IN`) on VARCHAR **DO push down**.
- **Range predicates** (`<`, `>`, `BETWEEN`) on VARCHAR **do NOT push down by default** (because of collation correctness concerns).
- Range pushdown can be enabled with the experimental `postgresql.experimental.enable-string-pushdown-with-collate` / session property `enable_string_pushdown_with_collate`.

Worse, the answer's own example query uses `WHERE u.status = 'active'` — an equality predicate on a VARCHAR column, which **does** push down. The engineer following the advice would incorrectly suspect this exact filter as the source of the pushdown failure.

### `defaultRowFetchSize` recommendation incomplete and slightly out-of-date

`defaultRowFetchSize` is a real PostgreSQL JDBC driver connection-string parameter. However:
- Trino's PostgreSQL connector now (per PR #16644) **automatically picks fetch size in the range 1000–100,000** based on column count. Recommending "try 1000 or 5000" may actually *lower* the effective fetch size in some cases.
- The answer should clarify that `defaultRowFetchSize` is passed via the JDBC URL (`connection-url`), not as a catalog property name on its own.

### Missing diagnostic angles

- **No mention of `system.runtime.tasks`** (which gives per-stage/task timing and is often what the UI surfaces).
- **No mention of the per-operator "Blocked" time** in EXPLAIN ANALYZE VERBOSE — a key signal that distinguishes "slow because waiting on upstream" from "slow because doing CPU work."
- **No mention of `pg_stat_activity` on the PostgreSQL side** as a cross-check (the engineer asked specifically not to set up external monitoring, but checking the existing PostgreSQL database's own activity view is not "external monitoring infrastructure").
- The answer says "Compare: if Iceberg scan takes 5 seconds and PostgreSQL takes 25 seconds" but does not explain that operator wall times overlap in pipelined execution — naive summation overstates the bottleneck.

### Minor

- Production environment uses Trino 467; the answer doesn't anchor any version-specific claims (acceptable since most of these features predate 467).
- No mention that EXPLAIN ANALYZE VERBOSE output can be hundreds of lines and that the Trino UI's "Stage Performance" view is often easier than reading raw text.

## Verification notes

Verified via WebSearch against trino.io official docs and Trino GitHub:

1. **EXPLAIN ANALYZE VERBOSE per-operator timing**: Confirmed. Format is `CPU: [time], Scheduled: [time], Output: [rows]` per operator. (trino.io/docs/current/sql/explain-analyze.html)
2. **`dynamicFilterSplitsProcessed`**: Confirmed real, introduced in PR #3217, appears on ScanFilterAndProjectOperator stats. (github.com/trinodb/trino/pull/3217)
3. **`system.runtime.queries` columns**: Confirmed `query_id`, `user`, `state`, `created`, `source`, `queued_time_ms`, `analysis_time_ms`, `planning_time_ms` all exist. (trino.io/docs/current/connector/system.html)
4. **`user` as reserved word**: Confirmed, must be double-quoted.
5. **`dynamic-filtering.wait-timeout` catalog placement**: This is a **probe-side** property. The Iceberg connector exposes `iceberg.dynamic-filtering.wait-timeout` (default 1s per trino.io/docs/current/connector/iceberg.html). For a join where Iceberg = probe and PostgreSQL = build, the binding wait is on the Iceberg side. Answer's recommendation to set it in `app_pg.properties` is WRONG.
6. **PostgreSQL VARCHAR pushdown**: Per trino.io/docs/current/connector/postgresql.html, equality on VARCHAR DOES push down; only range predicates do not by default. Answer's blanket "VARCHAR does NOT push down" is wrong.
7. **`defaultRowFetchSize`**: Real PostgreSQL JDBC parameter, but Trino now auto-tunes fetch size 1000–100,000 (PR #16644).

## Recommendation for teacher

1. **HIGH (correctness)** — Update the federation observability resource to state explicitly: "`dynamic-filtering.wait-timeout` is a probe-side connector property. Set it on the catalog that owns the LARGER table in the join (the one whose splits are being pruned by the DF), not on the build-side connector. For an Iceberg-probe / Postgres-build topology, set `iceberg.dynamic-filtering.wait-timeout` in `etc/catalog/iceberg.properties`." Include a worked example with both topologies (Iceberg-probe and Postgres-probe).
2. **HIGH (correctness)** — Correct the VARCHAR pushdown claim. State precisely: "Equality and IN predicates on VARCHAR DO push down to PostgreSQL. Range predicates (`<`, `>`, `BETWEEN`, `LIKE`) on VARCHAR DO NOT push down by default; experimental opt-in via `postgresql.experimental.enable-string-pushdown-with-collate` exists but has performance trade-offs." Remove the misleading "VARCHAR predicates do not push down" blanket statement.
3. **MEDIUM (completeness)** — Add a section on `Blocked` time in EXPLAIN ANALYZE VERBOSE operator stats and how to interpret it (probe waiting on build vs. probe waiting on downstream consumer).
4. **MEDIUM (completeness)** — Note that Trino auto-tunes JDBC fetch size in range 1000–100,000 since recent versions; explicitly setting `defaultRowFetchSize=1000` can be a regression. Recommend measuring first.
5. **LOW (clarity)** — Add a callout that operator wall times overlap due to pipelined execution, so the sum of operator times exceeds total query wall time; use *relative* dominance, not subtraction, to identify bottlenecks.
6. **LOW (completeness)** — Mention `system.runtime.tasks` and the Trino UI Stage Performance view as additional zero-infrastructure observability surfaces.

Sources:
- [Trino EXPLAIN ANALYZE docs](https://trino.io/docs/current/sql/explain-analyze.html)
- [Trino Dynamic Filtering docs](https://trino.io/docs/current/admin/dynamic-filtering.html)
- [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html)
- [Trino PostgreSQL connector docs](https://trino.io/docs/current/connector/postgresql.html)
- [Trino System connector docs](https://trino.io/docs/current/connector/system.html)
- [PR #3217: dynamicFilterSplitsProcessed](https://github.com/trinodb/trino/pull/3217)
- [PR #16644: auto-tune JDBC fetch size](https://github.com/trinodb/trino/pull/16644)
