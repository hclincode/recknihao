# Iter 164 Q2 — Judge Score

**Phase**: extended (post-final)
**Topic**: Trino federation / cross-source connectors (debugging slow Iceberg-Postgres join, EXPLAIN ANALYZE, Postgres-side tools)
**Production stack**: On-prem k8s, Trino 467, Iceberg 1.5.2, MinIO, Hive Metastore, OSS Trino (no Starburst)

## Question

> Trino joining Iceberg events (billions of rows) to a small Postgres lookup (5K rows) is slow. The user has tried EXPLAIN ANALYZE in the Trino UI but doesn't know what to look for. What to look for, and are there Postgres-side tools to see what Trino is actually doing?

## Per-dimension scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy (×2) | 3 | Core diagnosis framework (dynamic filtering, predicate pushdown, connection saturation) is right. Two factual errors verified against trino.io 467 docs: (a) `iceberg.dynamic-filtering.wait-timeout` **default is `1s`, not `2s`** (confirmed at https://trino.io/docs/467/connector/iceberg.html — answer says "default in Trino 467 is only 2 seconds"); (b) the SQL `SET SESSION dynamic_filtering_wait_timeout = '15s'` will **fail with "Session property does not exist"** — it is a *catalog* session property requiring a prefix, e.g., `SET SESSION iceberg.dynamic_filtering_wait_timeout = '15s'`. An engineer copy-pasting this exact statement gets an error. `dynamicFilterSplitsProcessed` field name in EXPLAIN ANALYZE is correct. `pg_stat_activity` columns and `log_min_duration_statement` workflow are correct. PgBouncer + role-level CONNECTION LIMIT advice is correct. "OSS Trino 467 PostgreSQL connector has no native connection pooling" is correct (verified: trinodb/trino#15888 still open). `postgresql.experimental.enable-string-pushdown-with-collate` is the correct Trino 467 property name. |
| Beginner clarity | 4 | Well-structured: three named root causes with how-to-test for each, plus a "what to do right now" checklist. Jargon mostly explained inline ("the probe side starts without a filter," "files pruned at runtime"). Minor: `ScanFilterProject`, `Blocked: Input`, `Physical Input` are mentioned without saying where exactly in the EXPLAIN ANALYZE output they appear (UI vs CLI text format), which a Trino-UI beginner needs. `Filter` node "above" the scan is a visual-graph concept the user has to map back. |
| Practical applicability | 3 | Structure is excellent — a sequenced checklist, copy-pasteable queries, named pg_stat_activity columns. But the central fix (`SET SESSION dynamic_filtering_wait_timeout = '15s'`) does not work as written in Trino 467, so the engineer following the answer step-by-step hits an error at the most important step. They will likely figure out the catalog-prefix variant or googling it, but the primary "do this" sentence in the answer is broken. Also the `EXPLAIN (TYPE DISTRIBUTED)` step is good but should call out that the user can view the same plan in the Trino UI's Plan tab — the question explicitly mentions Trino UI literacy. |
| Completeness | 4 | Covers all three angles the question asked: (1) what to look for in EXPLAIN ANALYZE, (2) root causes specific to this small-Postgres-big-Iceberg pattern, (3) Postgres-side tools (`pg_stat_activity`, slow query log, replication lag). Misses: (a) `system.runtime.tasks` and Trino UI's per-stage timeline, which would tell the user *which* stage is slow; (b) no mention of join distribution type (broadcast vs partitioned) — this is the highest-leverage knob for a small-dimension join and is documented in resource 22 section 5.5; (c) no callout that with 5K rows the join should naturally fit broadcast distribution and that the user should verify `SET SESSION join_distribution_type = 'BROADCAST'` isn't being overridden. |

**Weighted score** = (3×2 + 4 + 3 + 4) / 5 = **3.40 / 5** — **FAIL** (topic threshold is 4.5; pass threshold for this topic is raised because of iter158/163 failures)

## Verification log

Per CRITICAL verification requirement, I checked each specific claim:

1. **`dynamicFilterSplitsProcessed` in EXPLAIN ANALYZE output (Trino 467)**: CONFIRMED. The metric is documented in trino.io's dynamic filtering admin page as appearing in `ScanFilterAndProjectOperator` stats. It "records the number of splits processed after a dynamic filter is pushed down to the table scan." The answer's framing of "non-zero means DF fired and pruned splits" is correct.

2. **Default `dynamic_filtering_wait_timeout` is 2 seconds in Trino 467**: **WRONG**. Trino 467 Iceberg connector docs (https://trino.io/docs/467/connector/iceberg.html) document `iceberg.dynamic-filtering.wait-timeout` with default **`1s`**. The Hive connector's `hive.dynamic-filtering.wait-timeout` is also `1s`. There is no global/coordinator-wide `dynamic-filtering.wait-timeout` documented in the admin properties page. The resource file (`resources/22-trino-federation-postgresql.md` line 460) repeats the "2s" number — this is a resource error that the responder faithfully reproduced.

3. **`SET SESSION dynamic_filtering_wait_timeout` works as a per-session override**: **WRONG without catalog prefix**. Per the Hive/Iceberg connector docs and Trino session-property semantics, `dynamic_filtering_wait_timeout` is a *catalog* session property. It must be invoked as `SET SESSION <catalog>.dynamic_filtering_wait_timeout = '15s'` (e.g., `SET SESSION iceberg.dynamic_filtering_wait_timeout = '15s'`). The bare `SET SESSION dynamic_filtering_wait_timeout = '15s'` errors with "Session property does not exist."

4. **`pg_stat_activity` and `log_min_duration_statement` are correct Postgres-side tools**: CONFIRMED. The pg_stat_activity columns the answer lists (`pid`, `query_start`, `state`, `query`, `usename`) are all real columns from the Postgres docs (https://www.postgresql.org/docs/current/monitoring-stats.html). The `ALTER SYSTEM SET log_min_duration_statement = 0; SELECT pg_reload_conf();` recipe is correct and reversible.

5. **OSS Trino 467 has no native PostgreSQL connection pooling**: CONFIRMED. Trinodb/trino issue #15888 ("Enable connection pooling for Postgresql") is still open as of May 2026. The Oracle connector is the only OSS Trino JDBC connector with native pooling. The answer's PgBouncer + role-level `CONNECTION LIMIT` advice is the correct OSS-stack mitigation.

## What the answer got right

- Correctly framed the three high-leverage failure modes for federated joins: dynamic filtering didn't kick in, predicate pushdown didn't happen, connection saturation.
- Correct `dynamicFilterSplitsProcessed` metric name and interpretation.
- Correct `EXPLAIN (TYPE DISTRIBUTED)` approach for inspecting the planned filter pushdown vs separate `Filter` node above scan.
- Correct `pg_stat_activity` query with `usename` filter to see SQL Trino is sending.
- Correct slow-query-log toggle recipe with cleanup (`log_min_duration_statement = -1`).
- Correct callout that OSS Trino 467 has no native PostgreSQL connection pooling; correct PgBouncer + role CONNECTION LIMIT recommendation.
- Correct mention that `LOWER(col)`, `DATE(col)`, and `LIKE/>/<` on VARCHAR block pushdown.
- Correct `postgresql.experimental.enable-string-pushdown-with-collate` property name.

## What the answer got wrong

- **Default `dynamic_filtering_wait_timeout` is documented as `1s` in Trino 467 Iceberg connector docs, not `2s`.** The resource file says 2s; this is a resource error.
- **The `SET SESSION dynamic_filtering_wait_timeout = '15s'` syntax is invalid** — catalog session properties require a `<catalog>.` prefix. The engineer following this answer will see "Session property does not exist."
- Did not mention join distribution type (`join_distribution_type = 'BROADCAST'`) — this is the most relevant tuning knob for a 5K-row Postgres × billions-of-rows Iceberg join and is the natural follow-up if DF doesn't fully solve it.
- Did not point the user to the Trino UI's per-stage view (the question literally said "I tried reading through the Trino UI" — the answer should bridge them from the UI's stage timeline into EXPLAIN ANALYZE).
- No mention of `system.runtime.tasks` for per-stage debugging.

## Resource fix recommendations

**HIGH (correctness)** — `resources/22-trino-federation-postgresql.md` section 5.4:
- Correct the default value: per https://trino.io/docs/467/connector/iceberg.html, `iceberg.dynamic-filtering.wait-timeout` default is `1s` (not `2s`). Update lines 460 and 508 of the resource.
- Correct the `SET SESSION` syntax: replace bare `SET SESSION dynamic_filtering_wait_timeout = '15s'` with **catalog-prefixed** form `SET SESSION iceberg.dynamic_filtering_wait_timeout = '15s'` (and `SET SESSION <pg_catalog>.dynamic_filtering_wait_timeout = '...'` if tuning the Postgres side). Add a callout: "this is a catalog session property — the catalog prefix is required; the bare form will error."

**MEDIUM (completeness)** — `resources/22-trino-federation-postgresql.md` or a new debugging resource:
- Add a "debugging a slow federated join" runbook that bridges Trino UI -> EXPLAIN ANALYZE -> Postgres-side tools, since this is now an actively asked angle.
- Always mention `join_distribution_type = 'BROADCAST'` as the first knob to check for "small Postgres dimension joined to big Iceberg fact" pattern.

**LOW (clarity)** — When recommending `Blocked: Input`, `Physical Input`, `ScanFilterProject`, briefly explain where in the EXPLAIN ANALYZE output (or Trino UI Plan tab) each appears, since the engineer self-identified as not knowing what they're looking at.
