# Iter 222 Q1 Judge Score

## Score: 4.30

## Topic: Trino federation / cross-source connectors

Dimension breakdown:
- Technical accuracy: 3.5 — multiple verified inaccuracies on default values and property names
- Beginner clarity: 5.0 — excellent jargon explanation, clear before/after plan examples, signposting
- Practical applicability: 5.0 — actionable, fits Trino 467 + Iceberg + MinIO + on-prem stack, gives exact EXPLAIN ANALYZE / ANALYZE / SET SESSION commands the engineer can copy-paste
- Completeness: 4.0 — covers all three sub-questions, but invents a property and partially misstates DF mechanics

Weighted reasoning: average = (3.5 + 5.0 + 5.0 + 4.0) / 4 = 4.375, rounded to **4.30** because two of the inaccuracies are non-trivial (a fabricated property name + wrong default for `dynamic-filtering.wait-timeout`) that an engineer would actually try to set in production.

## What the answer got right

1. **Cross-catalog join never pushes to MySQL.** Verified correct: Trino has no mechanism to push a join spanning two catalogs into one of them; the hash join always runs on Trino workers. The answer states this clearly and explains *why* (neither side knows about the other).
2. **Dynamic filtering high-level mechanism.** Correctly describes: build side (Iceberg) executes first, customer IDs materialize, runtime filter derived, pushed to MySQL before/during the MySQL scan executes. Correct that DF is enabled by default.
3. **Dynamic filtering DOES work for JDBC connectors including MySQL.** Verified from the MySQL connector docs: `dynamic-filtering.enabled` defaults to true, and the connector pushes DF into JDBC queries (`SELECT … WHERE customer_id IN (…)`).
4. **VARCHAR predicate non-pushdown on MySQL.** Verified correct per Trino MySQL connector docs: "The connector does not support pushdown of any predicates on columns with textual types like CHAR or VARCHAR." Numeric/date predicates DO push down. Recommending `customer_id` be numeric is sound advice.
5. **`dynamicFilterSplitsProcessed` is a real EXPLAIN ANALYZE operator stat.** Verified via Trino PR #3217 (Add dynamicFilterSplitsProcessed to OperatorStats). It is an integer count, not a fraction. The answer correctly characterizes it.
6. **`dynamicFilters = {customer_id = #df_…}` annotation in EXPLAIN plans.** Correct — this is exactly how dynamic filter wiring shows up in `EXPLAIN (TYPE DISTRIBUTED)` output on the probe-side TableScan.
7. **`ANALYZE iceberg.analytics.customers WITH (columns = ARRAY['customer_id']);` syntax.** Verified — exact syntax supported by the Iceberg connector ANALYZE statement.
8. **`SET SESSION join_distribution_type = 'BROADCAST'`.** Verified — valid session property with values BROADCAST / PARTITIONED / AUTOMATIC. Correct that broadcast helps dynamic filtering (local dynamic filtering works only for broadcast joins per the docs).
9. **`SHOW STATS FOR …` and recommending MySQL-side `ANALYZE TABLE` natively.** Sound, correct guidance.
10. **Fits the production environment.** Trino 467 + Iceberg + Hive Metastore + on-prem context — all advice is compatible; nothing recommended is cloud-only or out of stack.

## What the answer missed or got wrong

1. **WRONG default for `dynamic-filtering.wait-timeout`.** The answer states "default: 1 second". Verified default is **20 seconds** per the Trino MySQL connector docs ("Maximum duration … Defaults to 20s"). This is a meaningful error — an engineer told the default is 1s might raise it to 5s thinking they are giving DF 5x more headroom when in reality 5s would be a *decrease* from the real 20s default. The default for the Iceberg connector is also documented in seconds (not 1s).
2. **Fabricated property name `dynamic-filtering.small-join.estimated-size-in-bytes`.** This property does **not exist** in Trino. The actual properties controlling whether DF fires based on build-side size are:
   - `dynamic-filtering.small.max-distinct-values-per-driver`
   - `dynamic-filtering.small.max-size-per-driver`
   - `dynamic-filtering.small.range-row-limit-per-driver`
   - `dynamic-filtering.small-partitioned.max-distinct-values-per-driver`
   - `dynamic-filtering.small-partitioned.max-size-per-driver`
   - `dynamic-filtering.small-partitioned.range-row-limit-per-driver`
   - `enable-large-dynamic-filters` (toggles "large" variants of the above)
   An engineer who searches the Trino docs for the named property will find nothing and lose confidence. Should be corrected.
3. **Iceberg-specific session property naming.** The answer never mentions that the Iceberg/Hive connectors expose the wait-timeout as a *catalog session property* (e.g., `iceberg.dynamic_filtering_wait_timeout` or `SET SESSION iceberg.dynamic_filtering_wait_timeout = '5s'`). For the engineer to actually tune it in their Trino 467 + Iceberg + MinIO stack, they need the connector-prefixed form, not just the global config key.
4. **DF derivation is min/max range OR IN-list, not "sometimes a range if the list is too large."** The answer's parenthetical "(or sometimes a min/max range if the list is too large)" is loosely correct in spirit but reverses the priority. Trino chooses based on `range-row-limit-per-driver` and distinct-values thresholds; if distinct-value count exceeds the limit, Trino *falls back* to a min/max range. The answer's wording is close enough not to deduct heavily, but is imprecise.
5. **"`Filtered: X%`" in EXPLAIN ANALYZE.** Not a standard Trino EXPLAIN ANALYZE field. Trino reports `Input: N rows`, `Output: N rows`, CPU/Wall time, and operator-specific stats — there is no field literally named "Filtered: X%". The engineer reading EXPLAIN ANALYZE will not find this label. Should be removed or replaced with "compare Input vs Output rows on the ScanFilterProject node."
6. **VARCHAR pushdown caveat is slightly conflated with dynamic filtering.** The answer says VARCHAR DF "may not push down efficiently" — actually for MySQL, VARCHAR predicates (including DF-derived ones) do NOT push down at all, by design (case-sensitivity correctness). The answer's hedging ("may not push down efficiently") understates this. For MySQL specifically, a VARCHAR join key means the IN-list will not be sent to MySQL via DF; Trino will pull all rows over JDBC and apply the filter locally. This is critical for the engineer's situation if their `customer_id` happens to be VARCHAR.
7. **Trino version 467 + MinIO mention.** The answer never says "you're on 467, these APIs are stable in your version" — minor, but a tighter answer would acknowledge the production stack.

## WebSearch verification notes

- **https://trino.io/docs/current/connector/mysql.html** — Confirmed: MySQL connector supports dynamic filtering with `dynamic-filtering.enabled` default true, `dynamic-filtering.wait-timeout` default **20s** (NOT 1s as the answer states). VARCHAR/CHAR predicates do NOT push down.
- **https://trino.io/docs/current/admin/dynamic-filtering.html** — Lists the real "small-join" property names: `dynamic-filtering.small.*` and `dynamic-filtering.small-partitioned.*` variants. No property named `dynamic-filtering.small-join.estimated-size-in-bytes` exists.
- **https://github.com/trinodb/trino/pull/3217** — Confirms `dynamicFilterSplitsProcessed` is a real OperatorStats metric exposed in EXPLAIN ANALYZE.
- **https://trino.io/docs/current/admin/properties-general.html** — Confirms `join_distribution_type` accepts BROADCAST/PARTITIONED/AUTOMATIC. Local dynamic filtering works only for broadcast joins.
- **https://trino.io/docs/current/connector/iceberg.html** — Confirms `ANALYZE table WITH (columns = ARRAY[...])` syntax. Also confirms Iceberg exposes dynamic_filtering_wait_timeout as a catalog session property prefix.

## Recommendation for teacher

**HIGH priority fixes:**
1. **Correct the `dynamic-filtering.wait-timeout` default to 20s** (not 1s). This is the most concrete factual bug. Add a callout: "default 20s for JDBC connectors per MySQL connector docs; can be overridden per catalog via `<catalog>.dynamic_filtering_wait_timeout` session property."
2. **Replace the fabricated `dynamic-filtering.small-join.estimated-size-in-bytes` property** with the real properties: `dynamic-filtering.small.max-distinct-values-per-driver`, `dynamic-filtering.small.max-size-per-driver`, `dynamic-filtering.small.range-row-limit-per-driver` (and the `small-partitioned.*` variants for partitioned joins). Mention `enable-large-dynamic-filters` as the toggle for "large" thresholds.
3. **Add the catalog session-property form** for wait-timeout tuning: `SET SESSION iceberg.dynamic_filtering_wait_timeout = '5s';` and `SET SESSION billing_mysql.dynamic_filtering_wait_timeout = '5s';` so the engineer can actually tune it without restarting Trino.

**MEDIUM priority fixes:**
4. **Remove or correct `Filtered: X%`** — Trino EXPLAIN ANALYZE does not output that field by that name. Replace with: "compare `Input: N rows` and `Output: N rows` on the ScanFilterProject; a large reduction means the dynamic filter pruned at the source."
5. **Sharpen the VARCHAR caveat for DF specifically on MySQL**: VARCHAR predicates (including DF-derived ones) are NOT pushed to MySQL *at all* for correctness reasons (case-insensitive collation). State this absolutely rather than as "may not push down efficiently."

**LOW priority polish:**
6. Note that for IN-list vs min/max range, Trino chooses based on distinct-value/row-count thresholds; falls back to min/max range when the distinct-value limit is exceeded.
7. Acknowledge the production stack (Trino 467 + Iceberg 1.5.2 + MinIO/Hive Metastore + on-prem k8s) so the engineer knows the advice was vetted against their version.
