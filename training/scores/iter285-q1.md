# Score — Iter285 Q1

**Score: 4.43/5.0 FAIL** (below 4.5 pass threshold)

## Breakdown
- Technical accuracy (40%): 4/5 — All headline numerics correct (domain-compaction-threshold default 256, iceberg.dynamic-filtering.wait-timeout default 1s, enable_large_dynamic_filters is a real Trino 467 session property, BETWEEN range compaction behavior accurate). BUT one prominent code example is wrong: `SET SESSION iceberg.dynamic_filtering_wait_timeout = '20s';` — the Iceberg connector does NOT expose `dynamic_filtering_wait_timeout` as a catalog session property (only Hive, Delta Lake, and Kudu do). For Iceberg in Trino 467 the only way to change this is the catalog-level config property `iceberg.dynamic-filtering.wait-timeout=20s` in `etc/catalog/iceberg.properties` followed by coordinator/worker restart. The engineer will get "Session property does not exist" if they paste this. Also recurring rubric gap: the catalog-prefixed session property form is not consistently shown (the doc-config example shows `iceberg.dynamic-filtering.wait-timeout` which matches the property name in `etc/catalog/iceberg.properties` if the catalog file is named `iceberg.properties` — that part is fine).
- Completeness (25%): 5/5 — Three-stage cascade (compaction → wait timeout → DF generation cap) is clearly enumerated, plus EXPLAIN/EXPLAIN ANALYZE diagnostics with `dynamicFilters = {...}` and `dynamicFilterSplitsProcessed > 0` checks, plus selective-predicate workaround, plus the structural fix (CTAS + MERGE INTO into Iceberg). Hits all six answer-key claims.
- Production fit (20%): 4/5 — On-prem Trino 467 + Iceberg + MinIO is well respected. CTAS + MERGE INTO works in Trino 467 with the Iceberg connector. Catalog name `app_pg` matches the established convention. The phantom Iceberg session property is the only production-fit slip; an engineer trying the suggested SET SESSION will be blocked. Should have either (a) shown only the `etc/catalog/iceberg.properties` config form with a note that it requires restart, or (b) suggested raising the Hive-style `dynamic_filtering_wait_timeout` on the Postgres catalog where applicable.
- Clarity (15%): 5/5 — The three-stage failure cascade is exceptionally well structured with named stages, then a one-to-one fix list, then a summary table. EXPLAIN-vs-EXPLAIN-ANALYZE branch logic ("Present → check dynamicFilterSplitsProcessed; Absent → enable_large_dynamic_filters") is crisp and actionable.

Weighted: 0.40*4 + 0.25*5 + 0.20*4 + 0.15*5 = 1.60 + 1.25 + 0.80 + 0.75 = **4.40**

(Recomputed cleanly: 4.40/5.0 — below 4.5 pass threshold.)

## What was correct
- `domain-compaction-threshold` default 256 (verified at trino.io postgresql.html and connector docs)
- IN-list → BETWEEN MIN/MAX range compaction behavior at the threshold (verified concept)
- `iceberg.dynamic-filtering.wait-timeout` default `1s` (verified at trino.io/docs/current/connector/iceberg.html)
- `enable_large_dynamic_filters` is a real system session property in Trino 467 (introduced 342, removed 480 — production runs 467 so it applies)
- `dynamicFilters = {...}` annotation on TableScan, and `dynamicFilterSplitsProcessed` operator stat
- CTAS + MERGE INTO to ingest the lookup into Iceberg as the structural fix
- Selective WHERE predicate on Postgres side as a quick win

## Errors or gaps
- **HIGH (correctness)**: `SET SESSION iceberg.dynamic_filtering_wait_timeout = '20s';` is not a valid statement in Trino 467. The Iceberg connector exposes only the config-property form `iceberg.dynamic-filtering.wait-timeout` in `etc/catalog/iceberg.properties` (requires service restart). There is no per-session override for the Iceberg wait-timeout — unlike Hive (`<hive-catalog>.dynamic_filtering_wait_timeout`), Delta Lake, and Kudu connectors which do expose session forms. An engineer pasting this will get a "Session property does not exist" error and lose trust.
- **MEDIUM (clarity)**: Should disambiguate the system session property `dynamic_filtering_wait_timeout` (a coordinator-side default that the Iceberg connector ignores in favor of its own config) from the connector-specific catalog session form, given this is a recurring rubric gap (iter170 LOW item).
- **LOW (completeness)**: No mention of `EXPLAIN ANALYZE VERBOSE` (recurring rubric item) for per-operator dynamic-filter wait-time visibility; no mention of OPA/event-listener for postmortem on timed-out DFs (11+ iteration recurring gap, less critical here but would round it out).
- **LOW (completeness)**: At 2M distinct keys, even raising the wait-timeout produces a BETWEEN range that prunes only files whose [min,max] falls entirely outside [min_id, max_id] across 2M sparse keys — likely zero pruning. The answer says "limited help at 2M" in the table but the body text overstates that "waiting for it still beats Iceberg scanning 80M rows with no filter at all" when in practice the range is often near-useless on sparse, monotonically-allocated customer IDs. Mild overstatement.

## Verification
- **iceberg.dynamic-filtering.wait-timeout default**: VERIFIED `1s` via trino.io/docs/current/connector/iceberg.html ("Maximum duration to wait for completion of dynamic filters during split generation. Default: 1s"). No session-property form exposed by the Iceberg connector — confirmed by direct WebFetch of the Iceberg connector page session-properties section.
- **domain-compaction-threshold default 256**: VERIFIED at trino.io postgresql.html and across connector docs ("can be used to adjust the default value of 256 for this threshold").
- **enable_large_dynamic_filters**: VERIFIED real session property — introduced in Trino 342 (24 Sep 2020), REMOVED in Trino 480 (24 Mar 2026). Production runs Trino 467 (between 342 and 480), so the property IS valid in production. Teacher should add a forward-compatibility note that this property is being removed in 480.
- **BETWEEN range compaction**: VERIFIED — "Trino compacts large predicates into a simpler range predicate by default" per connector docs.
- **Catalog session prefix issue**: This is the 4th+ iteration where catalog-prefixed session property form has been a gap in the rubric history. The Iceberg case here is a NEW variant (Iceberg has NO session form for this property at all), worth a teacher note.

Sources:
- [Iceberg connector — Trino docs](https://trino.io/docs/current/connector/iceberg.html)
- [Dynamic filtering — Trino docs](https://trino.io/docs/current/admin/dynamic-filtering.html)
- [PostgreSQL connector — Trino docs](https://trino.io/docs/current/connector/postgresql.html)
- [Release 480 — Trino docs (enable-large-dynamic-filters removed)](https://trino.io/docs/current/release/release-480.html)
- [Release 342 — Trino docs (enable-large-dynamic-filters introduced)](https://trino.io/docs/current/release/release-342.html)
