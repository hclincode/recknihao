# Iter 233 Q1 Score

**Score: 4.75 / 5.0**
**Pass: YES** (threshold is 4.5 in extended/final phase)

## What was correct

- **Core concept correct**: Dynamic filtering is enabled by default in Trino 467; build-side (MySQL accounts) produces filter values pushed to probe-side (Iceberg events). This is exactly how DF is intended to work for JDBC+Iceberg federated joins.
- **Two-step verification flow is excellent**: `EXPLAIN (TYPE DISTRIBUTED)` for plan-time wiring (`dynamicFilters = {account_id = #df_...}`), then `EXPLAIN ANALYZE VERBOSE` for runtime confirmation (`dynamicFilterSplitsProcessed > 0`). This matches the documented best practice.
- **`dynamicFilterSplitsProcessed` is a real Trino field** — verified via PR #3217 and Trino docs/discussions. It appears in `ScanFilterAndProjectOperator` stats, which `EXPLAIN ANALYZE VERBOSE` surfaces. The interpretation (`> 0` means DF fired, `= 0` means timeout) is accurate.
- **Wait-timeout asymmetry is the headline insight and is correct**: Iceberg connector default `dynamic-filtering.wait-timeout = 1s`, while MySQL JDBC default = 20s. Verified against trino.io docs and the search results. The recommendation to raise Iceberg's wait-timeout to 20s to match the JDBC side is exactly the right fix.
- **Side-by-side good/bad EXPLAIN ANALYZE output** is very pedagogically effective — engineer can visually pattern-match against what they see.
- **VARCHAR caveat is accurate**: `domain-compaction-threshold` default of 256 is verified across Trino connector docs. The note that exceeding 256 distinct values triggers compaction into a `BETWEEN` range (over-fetching but still pruning) is correct.
- **Practically applicable**: Quick Checklist at the end gives the engineer a copy-pasteable 3-step verification flow. Catalog properties file path (`etc/catalog/iceberg.properties`) matches the on-prem Trino 467 + Iceberg + Hive Metastore stack from `prod_info.md`.
- **Honest framing**: "Your gut is right — and yes, Trino is doing it (probably)" sets the right expectation that verification is needed.

## What was wrong or missing

- **Minor: SET SESSION syntax uses connector name instead of catalog name**. The answer writes `SET SESSION iceberg.dynamic_filtering_wait_timeout = '20s';` but the actual syntax is `SET SESSION <catalog_name>.dynamic_filtering_wait_timeout = '20s';`. The answer's own SQL example uses `iceberg_catalog.analytics.events`, so the correct form for that engineer's setup would be `SET SESSION iceberg_catalog.dynamic_filtering_wait_timeout = '20s';`. This will confuse engineers whose catalog isn't literally named "iceberg" — and per the iter164 Q1 feedback in the rubric, this exact bare-form bug has come up before and should be flagged in resources.
- **Minor: "skip entire Parquet files" simplification is mostly true but incomplete** — dynamic filters in Iceberg also prune at the split-level via partition predicates and file-stats. The mention of "min/max statistics" is correct for Parquet row-group level pruning, but the dominant Iceberg-side mechanism is partition pruning + manifest-list filtering. Not a big deal at this level of audience.
- **Missing: a note on join build/probe orientation** beyond "the join is backwards" — could have mentioned `SET SESSION join_distribution_type = 'BROADCAST'` or `join_reordering_strategy` as a way to ensure MySQL stays the build side. The answer does correctly identify that flipping is "unlikely at 500M rows" but doesn't explain how to force/verify it.
- **Missing: brief mention of the Trino UI Query Details page**, which exposes per-operator dynamic-filter stats in a more digestible way than VERBOSE plan output. A nice-to-have for the SaaS engineer audience.

## Verification notes

Verified against trino.io/docs/current and related searches:
- **Iceberg `dynamic-filtering.wait-timeout` default = 1s** — CONFIRMED.
- **JDBC (MySQL) `dynamic-filtering.wait-timeout` default = 20s** — CONFIRMED ("table scans are delayed up to 20 seconds until dynamic filters are collected").
- **`domain-compaction-threshold` default = 256** — CONFIRMED across PostgreSQL, MySQL, SQL Server, Druid connector docs.
- **`dynamicFilterSplitsProcessed`** — CONFIRMED as a real operator stat (PR #3217), appears in `ScanFilterAndProjectOperator` stats surfaced by `EXPLAIN ANALYZE VERBOSE`.
- **`EXPLAIN ANALYZE VERBOSE` showing DF wait time** — VERBOSE surfaces dynamic filter operator stats (collection time and ID per docs); the answer's claim is consistent with documented behavior.
- **`SET SESSION <connector>.dynamic_filtering_wait_timeout`** — the correct prefix is the **catalog name**, not the connector name. The answer's `iceberg.dynamic_filtering_wait_timeout` is correct ONLY if the catalog is literally named `iceberg`. Per the answer's own example, the catalog is `iceberg_catalog`, so the form shown is technically incorrect for the engineer's setup.

## Recommendation for teacher

- **MEDIUM (correctness)** — `resources/22-trino-federation-postgresql.md` (and any Iceberg DF section): when showing `SET SESSION ...dynamic_filtering_wait_timeout`, always write it as `<catalog_name>.dynamic_filtering_wait_timeout` with a callout that `<catalog_name>` is the user's actual catalog (e.g., `iceberg_prod`, not the connector name `iceberg`). This bug has now appeared in iter164 Q2 and iter233 Q1 — third strike if not fixed.
- **LOW (completeness)** — Add a short subsection on how to verify/force build-side orientation (`join_distribution_type`, `join_reordering_strategy`) so engineers know what to check if `EXPLAIN (TYPE DISTRIBUTED)` shows DF on the wrong side.
- **LOW (clarity)** — In the dynamic filtering section, note that the Trino Web UI Query Details page exposes per-operator DF stats more readably than the EXPLAIN ANALYZE VERBOSE plan tree.
- **POSITIVE PATTERN** — The structure of this answer (gut-check + plan-time signal + runtime signal + #1 pitfall + caveat + checklist) is a great template. The teacher should preserve this format in resources so future DF answers consistently follow it.
