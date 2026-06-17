# Judge Feedback — iter988 (EXTENDED PHASE breadth sweep)

**OVERALL 4.78125 — STRONG PASS** (Q1 4.75 / Q2 4.75 / Q3 4.8125 / Q4 4.8125 = 19.125/4 = 4.78125; margin +1.281; OVERALL AVERAGE governs, no per-Q veto).

All 4 questions verified BOTH directions against trino.io/docs/467 (functions/map.html, functions/array.html, sql/select.html GROUPING/ROLLUP, comparison.html + NOT-IN/NULL 3VL via WebSearch) — NOT against resources/. Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark ingestion + dbt): all four answers fit; NO federation drag-in, NO out-of-stack tooling.

---

## Q1 — NOT IN returns 0 rows despite users lacking Feb orders — **4.75 CLEAN**

VERIFIED CORRECT. The `NOT IN (subquery)` + NULL three-valued-logic trap is exactly right: if `orders.user_id` contains even one NULL, `user_id NOT IN (..., NULL, ...)` evaluates to UNKNOWN for every outer row (`x <> NULL` is UNKNOWN; NOT-UNKNOWN is UNKNOWN), the WHERE keeps only TRUE rows, so everything is filtered out → 0 rows. Confirmed standard SQL behavior (Postgres/MySQL/BigQuery/Snowflake identical) and confirmed Trino 467 behavior.
- Fix A `NOT EXISTS (SELECT 1 FROM orders o WHERE o.user_id=s.user_id AND o.order_month='2024-02')` is NULL-safe and decorrelates to an anti-join — CORRECT.
- Fix B `LEFT JOIN ... WHERE o.user_id IS NULL` is the equivalent **anti-join** — and the responder NAMED IT CORRECTLY as an anti-join. ★ NO false-mechanism semi-join mislabel (a known tic).
- "Never use NOT IN with a nullable subquery; reach for NOT EXISTS" is sound, correctly-scoped advice.
- ★ Stray "premium_users.user_id" example-table reference is a trivial COSMETIC wart (does not affect the deliverable logic), NOT a defect.
Acc 4.75 / Clar 4.75 / App 4.75 / Comp 4.75.

## Q2 — region + tier subtotals + grand total in one query — **4.75 CLEAN ★ KEY CHECK PASSED**

VERIFIED CORRECT both ways against sql/select.html GROUPING operation.
- `GROUP BY ROLLUP(region, tier)` is valid Trino 467 and produces: detail rows {region,tier}, region subtotal {region} with tier rolled up, and grand total {} with both rolled up — CONFIRMED.
- ★ **GROUPING(region, tier) bitmask CONFIRMED PRECISELY:** docs state grouping() returns a bit set where bit=1 when the column is NOT in the grouping (rolled up) and bit=0 when it IS a grouping column, and the **leftmost argument is the most-significant bit**. Therefore:
  - detail {region,tier} → 0b00 = **0** ✓ (responder: 0 = Detail)
  - region subtotal {region}, tier rolled up → region-bit 0, tier-bit 1 → 0b01 = **1** ✓ (responder: 1 = Region Total)
  - grand total {}, both rolled up → 0b11 = **3** ✓ (responder: 3 = Grand Total)
- ★ **"No value 2 for ROLLUP — don't write WHEN 2" CONFIRMED CORRECT:** value 2 = 0b10 = region rolled away + tier present = the {tier}-only grouping, which ROLLUP does NOT emit (that combination only comes from CUBE or explicit GROUPING SETS). Excellent, precise teaching.
- CUBE for independent margins on both dims and GROUPING SETS ((region),(tier),()) for hand-picked subtotals — both CORRECT.
The whole GROUPING-bitmask answer is subtle and the responder got every value right. ★ NO grouping-bitmask error (a watched tic). The only reason this isn't 5.0: clarity could note that NULL appears in the rolled-up columns of subtotal/total rows (the GROUPING() row_type label addresses this, but a beginner may still wonder where the NULLs come from).
Acc 4.875 / Clar 4.5 / App 4.75 / Comp 4.875.

## Q3 — count products with more than 3 tags (ARRAY length) — **4.8125 CLEAN**

VERIFIED CORRECT against functions/array.html.
- `count(*) ... WHERE cardinality(tags) > 3` — `cardinality(array)` returns the element count, CONFIRMED. `> 3` correctly maps to "more than 3" (keeps 4+). No sargability/function-wrap issue worth flagging here.
- "Trino has no array_length()" — CONFIRMED (cardinality is the canonical function; no array_length exists). NOT a fabrication-of-absence error.
- contains(tags,'featured'), array_distinct, array_join(tags, ', ') — all valid 467, CONFIRMED.
- "cardinality works on ARRAY and MAP (MAP = key count)" — CONFIRMED (cardinality(map) returns number of entries).
Acc 5.0 / Clar 4.75 / App 4.75 / Comp 4.75.

## Q4 — MAP filter properties['country']='US' type error — **4.8125 CLEAN ★ verified both ways**

VERIFIED CORRECT against functions/map.html.
- ★ **Subscript `map[key]` THROWS on a missing key — CONFIRMED.** Docs: the subscript operator "throws an error if the key is not contained in the map." `element_at(map, key)` "Returns value for given key, or NULL if the key is not contained in the map." So the element_at fix is exactly right: `element_at(properties,'country')='US'` returns NULL on missing keys, the WHERE drops them, no error. CORRECT both ways.
- Existence check `element_at(properties,'country') IS NOT NULL` — CORRECT.
- ★ NOTE: the user reported a "type error"; the actual production failure is most likely the missing-key RUNTIME error ("Key not present in map: ..."), not a static type error. The responder's element_at fix is correct regardless of which the user hit — NO ding. (Minor: the answer could have noted the user's "type error" wording might actually be the runtime missing-key error, but this is non-load-bearing.)
- JSON-string fallback (json_extract_scalar) — appropriate hedge, valid 467.
- ★ MAP type spelling: `MAP(VARCHAR,VARCHAR)` parens-syntax CORRECT; `MAP<VARCHAR,VARCHAR>` is Hive/Spark and parse-errors in Trino 467 — CONFIRMED. Good dialect-trap callout, no PARTITIONED-BY-style foreign-DDL drag-in.
Acc 4.875 / Clar 4.75 / App 4.75 / Comp 4.875.

---

## Scope notes / tics

- **Q1**: NOT-IN+NULL 3VL trap CORRECT; ★ anti-join CORRECTLY NAMED (no semi-join mislabel); stray "premium_users" = cosmetic wart only.
- **Q2 (KEY CHECK)**: ROLLUP valid; ★ GROUPING bitmask 0=detail / 1=region-subtotal / 3=grand-total CONFIRMED CORRECT (leftmost=MSB, bit=1 when rolled up); ★ "no value 2 for ROLLUP" CONFIRMED CORRECT (2=0b10={tier}-only, CUBE/GROUPING-SETS-only). NO grouping-bitmask error.
- **Q3**: cardinality(array)=length CONFIRMED; no array_length() CONFIRMED; contains/array_distinct/array_join valid; cardinality(map)=key count CONFIRMED.
- **Q4**: ★ subscript `map[key]` THROWS on missing key + element_at returns NULL — CONFIRMED both ways; element_at fix correct; MAP(...) parens correct, MAP<> Hive/Spark parse-error CONFIRMED.

TICS OTHERWISE CLEAN: no QUALIFY-misuse / false-mechanism-semi-join-mislabel (Q1 anti-join correctly named) / MAX(varchar) / percent_rank-inversion / fabricated-fn-or-rule (cardinality, element_at, GROUPING, ROLLUP, contains, array_join all real 467; array_length correctly stated ABSENT) / PARTITIONED-BY-foreign-DDL / aggregate-in-GROUP-BY / broken-secondary-false-justification / ILIKE-conflation / grouping-bitmask-error / mid-churn / missing-CTE-col / JOIN-fan-out / ts-minus-ts / column-scope.

## Recommendation = DEFAULT NO-OP

Margin +1.281; all 4 leads correct; all dialect/logic claims verified both directions. The only blemishes are sub-cosmetic (Q1 stray table name; Q2 NULLs-in-subtotal-rows could be spelled out for beginners). NO findable resource defect, NO findability gap, NO 2-in-2 recurrence. Q2 GROUPING-bitmask and Q4 map-subscript-throws — both subtle, both nailed.

Re-probe next sweep: (a) another GROUPING/CUBE/GROUPING SETS Q to confirm the bitmask convention stays correct under CUBE (where value 2 DOES appear) — watch whether the responder correctly emits/explains the {tier}-only row; (b) another MAP/ARRAY collection-access Q to confirm element_at-vs-subscript and cardinality stay correct.

Federation r22 §13.x hard-locked — NOT probed (OVERRIDDEN). NO resource edits. DO NOT bump training/state.json (already 988; passed=true preserved; final_iterations_remaining 0).
