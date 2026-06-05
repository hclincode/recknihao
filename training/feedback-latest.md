# Iter 495 Judge Feedback — 2026-06-06

**Overall: 4.5156 PASS** (94th consecutive overall PASS in extended phase; +1.016 above 3.5 floor)

**Q1 partition-key fix CONFIRMED LANDED.** Responder now writes `properties={'partitioning': "ARRAY[...]"}` for dbt-trino Iceberg models — the dialect-correct form per trino.io Iceberg connector docs. The iter494→495 reversal-from-stale-canonical (r28 LEADING CANONICAL + r27/r16/r13/r10 stale-block corrections) routed correctly on the re-probe with the new keyword phrasing.

**NEW CONFIRMED BUG (Q4):** GROUPING() bitmask mapping is wrong. For `GROUP BY ROLLUP(region, product_category)`: detail=0, region-subtotal=1, grand-total=**3** (NOT 2). The responder's `CASE GROUPING(region, product_category) WHEN 2 THEN 'Grand Total'` will never match — the grand-total row falls through to NULL/ELSE and is mislabeled. There is also NO row with bitmask = 2 in a 2-column ROLLUP. Confirmed via trino.io/docs/current/sql/select.html GROUPING operation: "bits are assigned to the argument columns with the rightmost column being the least significant bit. For a given grouping, a bit is set to 0 if the corresponding column is included in the grouping and to 1 otherwise." Leftmost = MSB; both-rolled-up = binary 11 = 3.

---

## Per-question scores

### Q1 — NEW dbt Iceberg model: exact config() with partitioning=month+bucket
**Avg 4.875 STRONG PASS** (RE-PROBE OF ITER494 Q3 — FIX CONFIRMED LANDED)
- Accuracy 5.0 — `properties={'partitioning': "ARRAY['month(event_date)', 'bucket(customer_id, 16)']"}` is dialect-correct for the Iceberg connector. Confirmed at trino.io/docs/current/connector/iceberg.html: "If a table is partitioned by columns c1 and c2, the partitioning property is `partitioning = ARRAY['c1', 'c2']`." Confirmed at trino.io/docs/current/connector/hive.html that `partitioned_by` is the HIVE connector property (wrong dialect for this Iceberg-backed stack). Responder correctly states the key is `partitioning` and NOT `partitioned_by`; correctly notes dbt-trino passes the dict verbatim into the WITH(...) clause; correctly suggests SHOW CREATE TABLE for verification.
- Clarity 4.75 — explicit dialect contrast called out; SHOW CREATE TABLE verification path; no unexplained jargon.
- Actionability 5.0 — copy-pasteable exact block; engineer can drop into a .sql model file and run.
- Completeness 4.75 — covers materialized, properties dict, key contrast, verification. Could optionally mention `format_version=2` and `format='PARQUET'` for completeness, but the question asked specifically for the partition-key config and the answer nailed that.
- **Topic mapping**: Improving complex SQL performance on Trino with dbt (dbt-trino subdomain).

### Q2 — Oracle NVL / NVL2 → Trino equivalents
**Avg 4.75 STRONG PASS**
- Accuracy 5.0 — NVL→COALESCE is the canonical mapping (COALESCE is ANSI; Trino has no NVL). NVL2→`CASE WHEN c IS NOT NULL THEN a ELSE b END` is correct (Trino has no NVL2). N-ary note on COALESCE is correct.
- Clarity 4.75 — clean side-by-side mapping; no jargon.
- Actionability 4.75 — engineer can grep `NVL(`/`NVL2(` and rewrite directly.
- Completeness 4.5 — covers both target functions. Minor missing-nuance: could note COALESCE evaluates left-to-right and returns the first non-NULL of N args (extending NVL's 2-arg form), or note NVL2 type-promotion semantics. Not load-bearing.
- **Topic mapping**: Oracle PL/SQL→dbt/Trino migration (Oracle-specific function rewrites for Trino dialect).

### Q3 — ADD COLUMN plan_tier VARCHAR to existing Iceberg table: safe?
**Avg 4.875 STRONG PASS**
- Accuracy 5.0 — metadata-only commit CORRECT per Iceberg evolution spec (schema updates are metadata-only, no data files rewritten). v2 existing rows read NULL CORRECT (Iceberg column-ID-based reader returns NULL for column IDs not present in older files). NO DEFAULT clause on Trino 467 CORRECT — DEFAULT in ADD COLUMN was added in Trino 477 (release 477, Sep 2025). Read-time default-backfill is Iceberg format-v3 CORRECT — v2 has no read-time defaults. Trino UPDATE or Spark INSERT OVERWRITE for backfill CORRECT paths for this stack.
- Clarity 4.75 — direct yes/no on "safe" with the v2-specific behavior spelled out.
- Actionability 5.0 — engineer knows: run the ALTER (safe, instant), existing queries unaffected, new writes carry the value, backfill via UPDATE or INSERT OVERWRITE if needed.
- Completeness 4.75 — covers safety, performance (metadata-only, instant), read behavior on old rows, write behavior on new rows, backfill options, downstream-query impact.
- **Topic mapping**: Postgres-to-Iceberg ingestion (Iceberg schema evolution is the ingestion-side concern).

### Q4 — Subtotals + grand total in one Trino query (region × product_category)
**Avg 3.5625 PASS AT FLOOR — CONFIRMED GROUPING-BITMASK BUG**
- Accuracy 3.5 — ROLLUP(region, product_category) approach CORRECT; SUM(amount) CORRECT; replaces UNION ALL CORRECT; CUBE mention CORRECT. **BUG**: GROUPING bitmask mapping is wrong. For 2-column ROLLUP: detail row = binary 00 = **0** (correct in answer); region-subtotal (product_category rolled up) = binary 01 = **1** (correct in answer); grand-total (both rolled up) = binary 11 = **3** (responder said 2 — WRONG). The CASE `WHEN 2 THEN 'Grand Total'` will never match because no row has bitmask = 2 in a 2-column ROLLUP. The grand-total row falls through to the ELSE/NULL branch and is mislabeled. Confirmed via trino.io/docs/current/sql/select.html GROUPING() definition: "bits are assigned to the argument columns with the rightmost column being the least significant bit. For a given grouping, a bit is set to 0 if the corresponding column is included in the grouping and to 1 otherwise" — leftmost = MSB. So `GROUPING(region, product_category)` = (region_bit << 1) | product_category_bit; grand-total = (1<<1)|1 = 3.
- Clarity 4.25 — explanation reads cleanly but propagates wrong values to a beginner.
- Actionability 2.5 — engineer who copy-pastes this gets a query that runs but labels the grand-total row as NULL — silent semantic bug, hours of debugging, exactly the class of error that erodes trust in the responder.
- Completeness 4.0 — answers ROLLUP vs UNION ALL, mentions CUBE; misses GROUPING_SETS for arbitrary subtotal patterns, and most critically misses the correct bitmask values.
- **Topic mapping**: Improving complex SQL performance on Trino with dbt (advanced GROUP BY for migrated complex queries), with secondary touch on SQL query best practices for OLAP.

---

## Topic avg updates

| Topic | Before | After | Delta |
|---|---|---|---|
| Improving complex SQL performance on Trino with dbt (Q1 + Q4 both map here) | 4.7475/5 | (4.7475*5 + 4.875)/6 = 4.7688/6 → (4.7688*6 + 3.5625)/7 = **4.5964/7** | -0.1511 (Q4 GROUPING bug drags) |
| Oracle PL/SQL→dbt/Trino migration (Q2) | 4.5140/66 | (4.5140*66 + 4.75)/67 = **4.5175/67** | +0.0035 |
| Postgres-to-Iceberg ingestion (Q3) | 4.4970/165 | (4.4970*165 + 4.875)/166 = **4.4992/166** | +0.0022 |

Federation NOT probed — **4.49944/310 row UNCHANGED** per the iter472-495 standing directive.

---

## Concrete next-teacher actions for iter496

**PRIMARY (HIGH PRIORITY) — Q4 GROUPING bitmask hardening:**
1. Add a LEADING CANONICAL block at the top of the ROLLUP/CUBE/GROUPING_SETS section in `resources/28-complex-sql-performance-trino-dbt.md` (and cross-ref from `resources/07-analytical-query-patterns.md` if it covers subtotals) showing the EXACT bitmask table:

   ```
   For GROUP BY ROLLUP(c1, c2):
     - detail row (both present):           GROUPING(c1, c2) = 0  (binary 00)
     - subtotal per c1 (c2 rolled up):      GROUPING(c1, c2) = 1  (binary 01)
     - grand total (both rolled up):        GROUPING(c1, c2) = 3  (binary 11)
   Note: there is NO row with GROUPING() = 2 in a 2-column ROLLUP.
   The leftmost argument is the MOST-significant bit; bit=1 means "rolled up", bit=0 means "present in grouping".
   ```

2. Include a DO-WRITE / DO-NOT-WRITE contrast:
   - DO-WRITE: `CASE GROUPING(region, product_category) WHEN 0 THEN 'Detail' WHEN 1 THEN 'Region Total' WHEN 3 THEN 'Grand Total' END`
   - DO-NOT-WRITE: `WHEN 2 THEN 'Grand Total'` — value 2 cannot occur for ROLLUP of (region, product_category); the grand-total row would silently be NULL.

3. Add a quick reference table for 3-column ROLLUP(c1, c2, c3) bitmask values (0, 1, 3, 7) so engineers understand the pattern.

4. Add canonical example for GROUPING_SETS (arbitrary subtotal selection) with its bitmask interpretation, since the responder didn't mention it.

5. Quote the trino.io/docs/current/sql/select.html "GROUPING operation" section VERBATIM in the resource so the responder can pattern-match it (proven-effective leading-canonical-example bulletproofing pattern).

**SECONDARY (LOW PRIORITY) — Maintenance:**
- Q1/Q2/Q3 all strong; no resource changes needed for those subdomains.
- Consider cross-ref from Oracle migration r27 to the new ROLLUP/GROUPING canonical block (PL/SQL procedural subtotal patterns often migrate to ROLLUP + CASE GROUPING).

---

## Judge probe targets for iter496

1. **Q4 GROUPING-bitmask re-probe** (HIGH PRIORITY — verify the fix lands): Ask the responder to write a Trino query that produces region subtotals + grand total with explicit row labels. Score on whether `WHEN 3 THEN 'Grand Total'` appears (correct) vs `WHEN 2 THEN 'Grand Total'` (regression). Vary the question phrasing: "include a label column", "differentiate detail rows from subtotal rows", "use GROUPING() to tag the row type".
2. **3-column ROLLUP/GROUPING_SETS probe**: Ask for a query with `ROLLUP(country, state, city)` and a label CASE on GROUPING — correct values are 0/1/3/7. This stress-tests whether the responder generalizes the bitmask pattern beyond 2 columns.
3. **dbt-trino partition-key durability re-probe** (vary keyword phrasing): Use phrases like "dbt model materialized as Iceberg table partitioned by tenant_id", "dbt config for Iceberg incremental with partitioning", "what goes in the properties dict for partitioning a dbt-trino Iceberg model" — confirm `'partitioning'` continues to route (not `'partitioned_by'`) across multiple keyword entry points.
4. **Federation row**: continue NOT-PROBED per standing directive — do not touch the 4.49944/310 federation row this iteration.

---

## DO NOT touch this iteration

- §13.x federation guardrails in `resources/22-trino-federation.md` — UNTOUCHED.
- Federation rubric row 4.49944/310 — UNTOUCHED.
- r07 §5 Pattern B2 YoY/MoM canonical — UNTOUCHED (held in iter493/494).
- r27 §4.1A DECODE-NULL canonical — UNTOUCHED (held in iter494).
- r28 LEADING CANONICAL `partitioning` block + r27/r16/r13/r10 stale-block fixes from iter495 — UNTOUCHED (LANDED on this iteration).

---

## Confirmed status

- **Q1 dbt-trino partition-key fix**: **LANDED**. Responder writes `partitioning` (dialect-correct for the Iceberg connector). The iter494→495 reversal-from-stale-canonical strategy worked.
- **Q4 GROUPING bitmask bug**: **CONFIRMED**. Grand-total value should be 3, not 2. Teacher must add canonical hardening for iter496.
- **Overall iter495**: **PASS at 4.5156**, +1.016 above 3.5 floor. 94th consecutive overall PASS in extended phase.
