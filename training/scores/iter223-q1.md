# Iter 223 Q1 Judge Score

## Score: 4.80

## Topic: Trino federation / cross-source connectors

## What the answer got right

1. **Dynamic filtering mechanism is fully correct.** The build-side / probe-side framing is precise: Trino materializes join keys from the smaller (Iceberg) side, derives a compact IN-list / range filter, and pushes that to the probe (MySQL) side before the probe completes its scan. The "5,000 customers from Iceberg → IN-list of those IDs to MySQL" narrative matches official docs.

2. **`EXPLAIN (TYPE DISTRIBUTED)` plan-time check is accurate.** Looking for `dynamicFilters = {...}` on the probe-side TableScan is the right plan-time diagnostic. Verified against trino.io/docs/current/admin/dynamic-filtering.html — dynamic filter IDs appear on the ScanFilterProject/TableScan node tied to the corresponding `dynamicFilterAssignments` in the join.

3. **`dynamicFilterSplitsProcessed` is a real stat.** Confirmed via the Trino dynamic filtering docs and PR #3217 (raunaqmorarka). It is an integer in operator statistics on the table-scan operator; non-zero means DF pushed down and pruned splits at runtime.

4. **`dynamic-filtering.wait-timeout` default of 20s for JDBC connectors is correct.** Verified at trino.io/docs/current/connector/mysql.html — the MySQL connector page explicitly states `dynamic-filtering.wait-timeout` defaults to `20s`. This directly fixes the iter222 Q1 error (which had stated 1s).

5. **Real DF threshold property names are accurate.**
   - `dynamic-filtering.small.max-distinct-values-per-driver`
   - `dynamic-filtering.small.max-size-per-driver`
   - `dynamic-filtering.small.range-row-limit-per-driver`
   - `dynamic-filtering.small-partitioned.*` variants
   - `enable-large-dynamic-filters` (config) / `enable_large_dynamic_filters` (session)
   All verified as valid Trino properties. Calling out the fabricated `dynamic-filtering.small-join.estimated-size-in-bytes` and warning the reader against it is excellent — directly addresses the iter222 error.

6. **Catalog-prefixed session property form is correct.** `SET SESSION iceberg.dynamic_filtering_wait_timeout = '30s'` matches the documented form `<catalog-name>.dynamic_filtering_wait_timeout` from the Hive/Iceberg connector docs. The note that the bare form fails with "Session property does not exist" is correct and useful.

7. **VARCHAR pushdown limitation is accurate.** Verified at trino.io/docs/current/connector/mysql.html — "The connector does not support pushdown of any predicates on columns with textual types like CHAR or VARCHAR." The answer correctly extends this to DF IN-lists, recommends switching to a numeric surrogate key, and notes that DATE/TIMESTAMP join keys do push.

8. **`domain_compaction_threshold` catalog session property is correct** — verified default 256, and the `billing_mysql.domain_compaction_threshold = 1024` form is valid.

9. **Four-reason taxonomy is complete and well-organized.** Build size thresholds, wait-timeout, wrong join orientation, VARCHAR key — these are the four real reasons DF fails in practice. Symptoms tied to each are correct.

10. **Practical diagnostic flow** (EXPLAIN ANALYZE → EXPLAIN DISTRIBUTED → MySQL slow log → DESCRIBE join key type) is exactly what a SaaS engineer needs to actually solve the problem. Production-environment fit is excellent (Trino 467, Iceberg + MySQL catalogs).

## What the answer missed or got wrong

1. **`dynamicFilters` format simplification.** The answer shows `dynamicFilters = {df_customer_id_0 = ...}`, but the actual format in Trino EXPLAIN output is `dynamicFilters = {"probe_column_name" = #df_NNN}` — i.e., the key is the probe column name and the value is the filter ID (with a `#` prefix). This is a minor cosmetic inaccuracy: a reader grepping for `df_customer_id_0` would not find that literal token; they should be looking for the `#df_` filter ID and the column name. The semantic intent is right but the exact textual format is slightly off.

2. **`dynamicFilterSplitsProcessed` lives on the ScanFilterAndProjectOperator, not the TableScan node per se.** The answer refers to "MySQL TableScan node" — practically equivalent for a reader, but pedantically the stat is on the operator stats block of the scan operator. Not a real error, just a precision nit.

3. **Build-side wait-timeout is set via the probe-side connector, not the build-side.** The answer's section 6 says "For the Iceberg connector (build side): `SET SESSION iceberg.dynamic_filtering_wait_timeout = '30s'`". This is partially misleading. `dynamic_filtering_wait_timeout` controls how long the probe-side scan in that connector waits before giving up on the dynamic filter. So:
   - If MySQL is the probe (which it is here), the relevant property is `billing_mysql.dynamic_filtering_wait_timeout`.
   - `iceberg.dynamic_filtering_wait_timeout` only matters if Iceberg is the probe in some other query.
   The answer reverses the labelling ("Iceberg connector (build side)") — it should explain that the timeout is a probe-side property and the MySQL setting is the one that matters for this scenario. Then optionally also set the Iceberg one for symmetry. This is a moderate clarity error.

4. **Min/max range filter still pushes to MySQL.** Section 4(a) implies that exceeding the small thresholds means "switches from IN-list to min/max range … or skips DF entirely." The min/max range case is actually fine for JDBC — it still gets pushed as a `WHERE customer_id BETWEEN min AND max` predicate, which still helps. The answer doesn't make this distinction; a reader might think exceeding small thresholds = total DF failure, when in reality it degrades to a less selective but still useful range predicate. Minor accuracy gap.

5. **Missing mention of `ANALYZE` / table statistics impact on join orientation.** Section 4(c) says "Run `ANALYZE` on both tables" but doesn't explain that for Iceberg, statistics come from `ANALYZE iceberg.schema.table` (or are auto-maintained via metadata files), while for MySQL the connector uses the MySQL `information_schema` statistics. This is the production-relevant fix path the engineer would actually take. Minor completeness gap.

6. **Could mention `join_distribution_type` is also catalog-independent / session-global** — that nuance helps explain why it works even across federated catalogs.

## WebSearch verification notes

- **https://trino.io/docs/current/admin/dynamic-filtering.html** — Confirmed: `dynamicFilterSplitsProcessed` is a real operator stat; `dynamicFilters` annotation format is `dynamicFilters = {"col" = #df_NNN}`; `dynamic-filtering.small.*` and `dynamic-filtering.small-partitioned.*` thresholds exist; `enable_large_dynamic_filters` is a real session property (Trino release 342+).
- **https://trino.io/docs/current/connector/mysql.html** — Confirmed: `dynamic-filtering.enabled` defaults to true; `dynamic-filtering.wait-timeout` defaults to `20s`; "The connector does not support pushdown of any predicates on columns with textual types like CHAR or VARCHAR"; `domain-compaction-threshold` and `domain_compaction_threshold` (default 256) exist.
- **Hive/Iceberg connector docs** — Confirmed the catalog session form `<catalog>.dynamic_filtering_wait_timeout` is the documented form for both Hive and Iceberg connectors.
- **PR #22824 (Dith3r, "Enable large dynamic filters")** — Confirmed `enable_large_dynamic_filters` and `enable-large-dynamic-filters` are the right names.
- **PR #13334 (raunaqmorarka, "Implement dynamic filtering for JDBC connectors")** — Confirmed JDBC connectors support DF since this PR; default wait-timeout for JDBC = 20s.

## Recommendation for teacher

The resource is now in excellent shape on this topic — three of the four iter222 corrections landed cleanly (20s default, real property names, removed fabricated property). Remaining tweaks (none critical, all polish):

1. **Fix the `dynamicFilters` format** to show the real form: `dynamicFilters = {"customer_id" = #df_370}` (column name in quotes, `#` prefix on filter ID). Use a concrete example with realistic filter ID like `#df_370` rather than `df_customer_id_0`.

2. **Clarify that `dynamic_filtering_wait_timeout` is a probe-side property.** Rewrite section 6 to say: "Set `billing_mysql.dynamic_filtering_wait_timeout = '30s'` because MySQL is the probe in this query — this controls how long MySQL waits for the DF from the Iceberg build before scanning unfiltered." Drop or de-emphasize the `iceberg.dynamic_filtering_wait_timeout` example in this scenario (or keep it as a sidebar for when Iceberg is the probe).

3. **Clarify range filter still pushes.** Add one line: "When the build exceeds the small thresholds, Trino falls back to a min/max range filter — for JDBC, this still pushes as `WHERE customer_id BETWEEN minval AND maxval`, which still helps if the range is narrow. Full DF skip only happens above the large thresholds when `enable_large_dynamic_filters` is off."

4. **Optional**: Add `ANALYZE iceberg.schema.events` / `ANALYZE iceberg.schema.customers` to the join-orientation fix to ground it in actual SQL the engineer would type.

Overall this is a strong PASS for the federation topic. The 0.20 deduction is for (a) `dynamicFilters` literal format inaccuracy, (b) reversed probe/build-side timeout labelling, and (c) minor missing nuance on range-filter pushdown.
