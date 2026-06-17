# Judge Feedback — iter1033

**Overall: Q1 4.8125 / Q2 4.75 / Q3 4.8125 / Q4 4.75 → 4.78125 PASS** (76.5/16; margin +1.28125; overall average governs, no per-Q veto).

Verified BOTH directions against RAW git-tag 467 source (raw.githubusercontent.com/trinodb/trino/467/docs/...), NOT resources/. Prod stack (Trino 467 + Iceberg + MinIO + Hive Metastore) fits all 4; no federation/auth angle.

---

## Q1 — EVERY tag starts with 'e', no UNNEST — 4.8125 CLEAN

**Answer:** `all_match(tags, tag -> starts_with(tag, 'e'))` in WHERE.

- `all_match(array(T), function(T,boolean)) -> boolean` EXISTS — array.md: "Returns whether all elements of an array match the given predicate... `true` if all match (special case empty array → true); `false` if one+ don't; `NULL` if predicate is NULL for one+ and true for the rest."
- `starts_with(string, substring) -> boolean` EXISTS — string.md: "Tests whether `substring` is a prefix of `string`."
- For a single literal letter `'e'` (no `_`/`%`), starts_with and LIKE 'e%' are equivalent — NO escape issue (the literal-`_`/`%`-prefix trap from iter1029/1030 does NOT apply here; 'e' has no wildcard chars). No row explosion, single boolean expression in WHERE. Fully correct.
- Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75.

## Q2 — faster approximate unique count for a chart — 4.75 CLEAN

**Answer:** `approx_distinct(session_id)` (HyperLogLog), "2.3% standard error", "~100x faster/less memory", GROUP BY event_date + date-range filter; exact = COUNT(DISTINCT) with `SET SESSION distinct_aggregations_strategy = 'pre_aggregate'` / `'split_to_subqueries'`.

- `approx_distinct(x) -> bigint` and `approx_distinct(x, e) -> bigint` EXIST — aggregate.md: "approximation of count(DISTINCT x)... should produce a **standard error of 2.3%**, which is the standard deviation of the (approximately normal) error distribution." 2.3% verbatim CORRECT.
- "100x faster / 100x less memory" is a rough perf heuristic, not a doc figure. Defensible characterization (HLL is sub-linear memory vs exact distinct's per-key state); not an over-claim worth penalizing.
- **CRUCIAL secondary aside VERIFIED CORRECT:** `distinct_aggregations_strategy` IS a real 467 property (properties-optimizer.md), default AUTOMATIC, legal values `SINGLE_STEP / MARK_DISTINCT / PRE_AGGREGATE / SPLIT_TO_SUBQUERIES / AUTOMATIC`. The responder's cited `'pre_aggregate'` and `'split_to_subqueries'` are BOTH legal values. The property name is NOT fabricated and NOT confused with `mark_distinct_strategy` (no such separate property; MARK_DISTINCT is a value of this property). No defect.
- Acc 5 / Comp 4.75 / Clar 4.5 / App 4.75.

## Q3 — plan_tier×region detail + per-tier subtotal + grand total in ONE query — 4.8125 CLEAN

**Answer:** `GROUP BY ROLLUP(plan_tier, region)` + `CASE GROUPING(plan_tier,region) WHEN 0 'Detail' WHEN 1 'Plan Tier Total' WHEN 3 'Grand Total'`; ORDER BY GROUPING(...), plan_tier NULLS LAST, region NULLS LAST. States ROLLUP(a,b) = GROUPING SETS ((a,b),(a),()).

- **Bitmask VERIFIED (select.md GROUPING operation):** "bits are assigned to the argument columns with the rightmost column being the least significant bit... a bit is set to 0 if the corresponding column is included in the grouping and to 1 otherwise." So leftmost (plan_tier) = MSB; bit=1 = column AGGREGATED/excluded.
  - (plan_tier, region) grouping set → 0b00 = **0** = Detail (correct)
  - (plan_tier) grouping set [region rolled up] → 0b01 = **1** = Plan Tier Total (correct)
  - () grand total [both rolled up] → 0b11 = **3** = Grand Total (correct)
  - Mask 2 (0b10) never occurs under ROLLUP. Responder's 0/1/3 mapping and labels are EXACTLY correct.
- ROLLUP(a,b) = GROUPING SETS ((a,b),(a),()) CORRECT (select.md shipping example).
- Column-names-only pin respected (plain column names, no expressions in ROLLUP). NULLS-LAST ordering correctly separates real values from rollup-NULLs.
- Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75.

## Q4 — combine aligned name/value arrays into a key-value map — 4.75 CLEAN

**Answer:** `map(feature_names, feature_values)` 2-arg constructor; `cardinality()>0` guard; `feature_map['key']` lookup; `CROSS JOIN UNNEST(feature_map) AS t2(k,v)` to iterate; steers AWAY from `map_from_entries(zip_with(...))`.

- 2-arg `map(array(K), array(V)) -> map(K,V)` EXISTS — map.md: "Returns a map created using the given key/value arrays." Requires equal lengths (errors on mismatch); the question states arrays are same-length/aligned, so safe. CORRECT.
- `UNNEST(map) AS t(k,v)` expands map to key/value columns — confirmed.
- The "don't use the longer `map_from_entries(zip_with(...))`" steer is FINE — `map(keys,values)` is the direct/correct form, so this is NOT a broken-secondary; it's a valid simplification steer.
- **Minor completeness nuance (not a defect):** map subscript `feature_map['battery_capacity']` THROWS if the key is absent (map.md: subscript "throws an error if the key is not contained in the map"), whereas `element_at(feature_map, 'battery_capacity')` returns NULL. The example implicitly assumes the key exists; for defensive lookups element_at is safer. The responder did not flag this — costs a fraction on completeness only.
- Acc 5 / Comp 4.5 / Clar 4.75 / App 4.75.

---

## TICS check
`::` ABSENT all 4. No QUALIFY / false-semi-join / fabricated function / regex-backslash / INTERVAL quarter-week / OFFSET-before-LIMIT / generate_subscripts / broken-secondary / over-warning. All functions cited (all_match, starts_with, approx_distinct, GROUPING, ROLLUP, map, UNNEST) are real and verified. Session property `distinct_aggregations_strategy` + its two cited values verified real. Q1 literal-prefix correctly avoids the underscore-wildcard trap (literal 'e' has no wildcard chars).

## RECOMMENDATION = DEFAULT NO-OP
Margin +1.28125; all 4 clean; ZERO source-verified resource defects; no 2-in-2 same-shape slip. The two secondary points flagged for careful verification (Q2 session-property name/values, Q3 GROUPING bitmask) both resolved IN THE RESPONDER'S FAVOR against RAW 467 source. NO resource edit; NO FIX-A; NO git commit. MUST NOT bump state.json (already 1033; orchestrator commits).

Passive re-probe monitors (no action): (a) approx_distinct 2.3%-error + distinct_aggregations_strategy values; (b) ROLLUP/GROUPING bitmask 0/1/3 mapping from another column-count angle; (c) map(keys,values) vs element_at-NULL-vs-subscript-throws on absent key; (d) all_match + starts_with literal-prefix. Federation r22 hard-locked, NOT probed (4.49944/310).
