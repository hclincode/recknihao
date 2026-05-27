# Iter256 Q1 Score

**Score: 4.7 / 5.0** — PASS (threshold: 4.5)

## What was correct
- Direction of dynamic filtering correctly stated: build side (small, filtered) → probe side (large). Matches official Trino docs.
- Mechanism described accurately: build side hash table is built first, distinct join-key values are collected, then pushed as a runtime predicate into the probe-side scan before/during split generation.
- IN-list / TupleDomain pushdown described correctly, including file-level (Parquet min/max) pruning on Iceberg.
- Plan-time evidence: `dynamicFilters = {df_customer_id_0 = <...>}` annotation on the probe-side TableScan — matches the documented `dynamicFilters = {"ss_sold_date_sk" = #df_370}` form.
- Runtime evidence: `dynamicFilterSplitsProcessed` metric in EXPLAIN ANALYZE — confirmed as a real metric in the Trino docs; the "non-zero means the filter fired" interpretation is correct.
- `domain_compaction_threshold` default of **256** verified against Trino discussion #14019 and connector docs; collapse to BETWEEN min/max range is correctly described.
- Concrete fixes shown: SET SESSION `<catalog>.domain_compaction_threshold = 1024` (per-query) and `domain-compaction-threshold=1024` catalog property — both are real and applicable.
- `pg_stat_activity` on the Postgres replica as a way to inspect the actual SQL Trino issued — practical and correct.
- VARCHAR BETWEEN not pushing down to Postgres by default due to collation concerns — a real, well-known Trino JDBC pushdown caveat.
- Trino Web UI mention (`/ui/query.html?<query_id>`) for post-mortem inspection — accurate; the UI does expose per-operator dynamic filter stats.
- The "Input vs Output rows on the TableScan" diagnostic is the right thing to look at.
- Practical applicability is high: an engineer can run EXPLAIN, EXPLAIN ANALYZE, check the UI, and inspect Postgres all from this answer.

## Gaps or errors
- The "flipped case" explanation is slightly hand-wavy. When the user reverses tables, the CBO still picks the smaller side as build (correctly noted), so DF would in principle flow Iceberg → Postgres. The answer correctly observes Postgres won't use an index without a WHERE clause, but it could have been crisper that (a) the DF *does* still get derived, (b) it still gets pushed across JDBC, but (c) without an index on the Postgres probe column, the BETWEEN/IN doesn't help at the storage level — and Postgres scan time dominates regardless.
- Does not disambiguate the two `dynamic_filtering_wait_timeout` settings (Iceberg `iceberg.dynamic-filtering.wait-timeout` default 1s vs PostgreSQL session `<pg_catalog>.dynamic_filtering_wait_timeout` default 20s). This was previously called out as an LOW-priority gap in the rubric history and is still missing here — relevant because a too-short wait timeout can cause `dynamicFilterSplitsProcessed = 0` even when the plan shows DF wired.
- The "Dynamic filters" UI panel name is approximate; the exact label in current Trino UI is closer to per-operator stats rather than a labeled panel. Minor.
- The "build side timed out waiting to deliver its filter" sentence is correct in spirit but the term and tunable (`dynamic-filtering.wait-timeout`) is not named, which would have made the diagnostic actionable.

## WebSearch verification notes
- Verified against https://trino.io/docs/current/admin/dynamic-filtering.html:
  - Build side / probe side terminology and direction confirmed (smaller dimension table is build side; runtime predicates pushed to probe-side scans).
  - `dynamicFilters = {...}` annotation appears in EXPLAIN output exactly as the answer claims.
  - `dynamicFilterSplitsProcessed` is a real operator metric documented as "the number of splits processed after a dynamic filter is pushed down to the table scan."
  - EXPLAIN ANALYZE "Dynamic filters:" block with collection time and ranges is documented.
- Verified `domain_compaction_threshold` default = **256** via Trino connector docs (PostgreSQL/MySQL/SQL Server) and GitHub discussion #14019. Compaction collapses large predicates into a simpler range predicate (BETWEEN min/max). Both the per-catalog config (`domain-compaction-threshold`) and session property (`<catalog>.domain_compaction_threshold`) are correct.
- Verified that DF collection switches to min/max when `dynamic-filtering.max-distinct-values-per-driver` is exceeded — consistent with the answer's narrative even though not named explicitly.

Final score: **4.7** — PASS.
