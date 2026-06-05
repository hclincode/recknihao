# Iter 497 Judge Feedback — 2026-06-06 (EXTENDED PHASE)

**Overall: 4.328 PASS** (+0.828 above 3.5 floor) — 96th consecutive overall PASS in extended phase. Q3 MERGE answer FAILED on Trino-dialect accuracy (TWO Spark-isms in the same answer). Q1/Q2/Q4 all STRONG PASS.

---

## Per-question scores

### Q1 — CUBE re-probe (cross-tab all combinations, ROLLUP missed product-only) — **4.9375 STRONG PASS**

**Topic mapping**: Improving complex SQL performance on Trino with dbt (r28 LEADING CANONICAL GROUPING block).

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | CUBE(region, product) emits all 2^N = 4 groupings: value 0 = detail, 1 = region present + product rolled up, **2 = region rolled up + product present (the product-only subtotal that ROLLUP missed)**, 3 = grand total. Bitmask mapping `WHEN 0 'Detail' / WHEN 1 'Region Total' / WHEN 2 'Product Total' / WHEN 3 'Grand Total'` is dialect-correct per trino.io/docs/current/sql/select.html (rightmost arg = LSB, bit=1 means column rolled up). Responder EXPLICITLY noted "value 2 IS the product-only subtotal under CUBE" and "do NOT use value 2 as grand total (grand total is 3)" — the canonical's CUBE-vs-ROLLUP differentiation held. |
| Clarity | 4.75 | Binary 10 = region rolled up, product present is spelled out; CUBE-vs-ROLLUP value-set contrast is explicit. |
| Actionability | 5.0 | Copy-pasteable GROUP BY CUBE(region, product) + CASE GROUPING(...) labels. |
| Completeness | 5.0 | Addresses CUBE choice + row labeling + ROLLUP gap explanation. |

**CUBE/GROUPING re-probe FIX CONFIRMED LANDED**: the iter497 teacher r28 §LEADING CANONICAL block extension (4-col table + 2^N-1 rule + CUBE vs ROLLUP Count column) pattern-matched on the CUBE-angle re-probe. Zero recurrence of any ROLLUP-only "value 2 never appears" mis-application to the CUBE case. 6th successful instance of leading-canonical-example bulletproofing.

---

### Q2 — Trino map column extract by key — **4.8125 STRONG PASS**

**Topic mapping**: SQL query best practices for OLAP.

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | `element_at(map_column, 'key')` returns NULL if missing key — verified at trino.io/docs/current/functions/map.html ("Returns value for given key, or NULL if the key is not contained in the map"). Correctly contrasted with `map[key]` subscript that throws on missing key. json_extract_scalar alternative for VARCHAR-JSON columns is correct. MAP+element_at being prunable/faster than VARCHAR-JSON parsing is defensible. |
| Clarity | 4.75 | Both forms shown with the NULL-vs-error distinction. |
| Actionability | 4.75 | Copy-pasteable; engineer knows what to do for MAP vs JSON columns. |
| Completeness | 4.75 | Covers happy path + missing-key + JSON-string alternative. |

---

### Q3 — CDC upserts to Iceberg via MERGE in Trino — **2.6875 FAIL** (LOAD-BEARING — two Spark-isms in same answer)

**Topic mapping**: Postgres-to-Iceberg ingestion (CDC subdomain) + Improving complex SQL performance on Trino with dbt (MERGE subdomain).

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 2.0 | **TWO confirmed Spark-isms in a Trino MERGE answer** — both load-bearing because the example is presented as copy-pasteable. (See verification details below.) MERGE INTO IS supported on Iceberg in Trino 467 — that part is correct. ON clause structure is correct. But the WHEN MATCHED / WHEN NOT MATCHED bodies and the format-version setup line are both wrong dialect. |
| Clarity | 3.25 | Pattern is readable but the wrong examples mis-teach the engineer. |
| Actionability | 2.5 | Engineer copy-pasting this gets parse errors on both `SET TBLPROPERTIES (...)` and `UPDATE SET *` / `INSERT *`. |
| Completeness | 3.0 | Covers MERGE support + setup intent + concurrent-write cross-ref, but two of the three concrete code artifacts are wrong-dialect. |

**Spark-ism #1 — `ALTER TABLE ... SET TBLPROPERTIES ('format-version' = '2')` is NOT Trino syntax.**
- Verified at trino.io/docs/current/connector/iceberg.html and trino.io/docs/current/sql/alter-table.html.
- **Correct Trino form**: `ALTER TABLE iceberg.analytics.events SET PROPERTIES format_version = 2;` — bare identifier key (snake_case `format_version`, NOT hyphenated string `'format-version'`), integer literal value (NOT quoted string `'2'`).
- `SET TBLPROPERTIES (...)` with string-literal hyphenated keys is **Spark/Hive** syntax. Wrong engine.
- **ADDITIONAL FACT THE ANSWER MISSED**: Trino-created Iceberg tables already default to `format_version = 2` (docs verbatim: "Optionally specifies the format version of the Iceberg specification to use for new tables; 1, 2, or 3. **Defaults to 2.**"). So the upgrade step is only needed for v1 tables migrated in from elsewhere — for a fresh Trino-created table the line is unnecessary noise that mis-teaches "you must set this before MERGE." The answer's framing ("v1 (Hive-migrated default) lacks delete files") is half-right for Hive-migrated tables but wrong for Trino-native tables.

**Spark-ism #2 — `WHEN MATCHED THEN UPDATE SET *` and `WHEN NOT MATCHED THEN INSERT *` wildcards are NOT Trino syntax.**
- Verified at trino.io/docs/current/sql/merge.html. Trino MERGE BNF: `WHEN MATCHED [ AND condition ] THEN UPDATE SET ( column = expression [, ...] )` and `WHEN NOT MATCHED [ AND condition ] THEN INSERT [ column_list ] VALUES (expression, ...)`. **No wildcard form documented or supported.**
- `UPDATE SET *` / `INSERT *` is **Spark/Databricks-Delta** MERGE syntax (Delta Lake's auto-mapping shorthand). Wrong engine.
- **Correct Trino form** (the canonical CDC-upsert example the responder should have written):
  ```sql
  MERGE INTO iceberg.analytics.events t
  USING incoming_cdc s
    ON t.event_id = s.event_id
  WHEN MATCHED AND s.op = 'DELETE' THEN DELETE
  WHEN MATCHED THEN UPDATE SET
    payload     = s.payload,
    updated_at  = s.updated_at,
    op          = s.op
  WHEN NOT MATCHED THEN INSERT (event_id, payload, updated_at, op)
    VALUES (s.event_id, s.payload, s.updated_at, s.op);
  ```

**Combined classification**: this is the iter497 NEW LOAD-BEARING FAB CLASS — engine-confusion (Spark dialect spilled into a Trino answer) appearing TWICE in the SAME answer on the SAME topic (MERGE / Iceberg DDL). This is exactly the dialect-accuracy failure pattern that single-line stale-content corrections do NOT fix; the teacher must install a LEADING CANONICAL block in r27 §3.2 (or r28 MERGE subdomain) with the full explicit-column Trino MERGE example UP FRONT, plus a DO-NOT-WRITE banner listing both `SET TBLPROPERTIES` and `SET *` / `INSERT *` as Spark-isms that parse-fail on Trino.

---

### Q4 — Oracle (+) outer-join → Trino ANSI join — **4.875 STRONG PASS**

**Topic mapping**: Oracle PL/SQL → dbt + Trino SQL migration.

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | "(+) is Oracle-proprietary, parse error in Trino" CORRECT. `WHERE a.id = b.id(+)` → LEFT JOIN CORRECT (a-side preserved because (+) is on b). `WHERE a.id(+) = b.id` → RIGHT JOIN CORRECT. Rule "(+) always preserves the side it's NOT on" is the standard Oracle outer-join rule — verified at docs.oracle.com/cd/B19306_01/server.102/b14200/queries006.htm and atlassian.com/data/databases/left-and-right-joins-using-the-plus-sign-in-oracle. Side-dependent (NOT always LEFT) is the correct answer to the asked question. |
| Clarity | 4.75 | Worked example comma-join + WHERE(+) → ANSI LEFT JOIN ON is exactly what a migrating engineer needs. |
| Actionability | 5.0 | Copy-pasteable rewrite pattern. |
| Completeness | 4.75 | Directly answers "always LEFT or side-dependent" with the side-dependent rule + worked example for both directions. |

---

## OVERALL = (4.9375 + 4.8125 + 2.6875 + 4.875) / 4 = 17.3125 / 4 = **4.328 PASS**

Q3 2.6875 drags but the other three STRONG PASS scores keep the iteration above the 3.5 floor by +0.828.

---

## Topic average updates

- **Improving complex SQL performance on Trino with dbt** (Q1 CUBE re-probe maps here) — 4.6390/8 → (4.6390*8 + 4.9375)/9 = 42.0495/9 = **4.6722/9** (+0.0332).
- **SQL query best practices for OLAP** (Q2 element_at maps here) — 4.5236/54 → (4.5236*54 + 4.8125)/55 = (244.2744 + 4.8125)/55 = 249.0869/55 = **4.5288/55** (+0.0052).
- **Postgres-to-Iceberg ingestion** (Q3 CDC MERGE maps here) — 4.4992/166 → (4.4992*166 + 2.6875)/167 = (746.8672 + 2.6875)/167 = 749.5547/167 = **4.4884/167** (-0.0108 — Q3 FAIL drags this row; still PASS overall).
- **Oracle PL/SQL → dbt + Trino SQL migration** (Q4 (+) → ANSI join maps here) — 4.5209/68 → (4.5209*68 + 4.875)/69 = (307.4212 + 4.875)/69 = 312.2962/69 = **4.5260/69** (+0.0051).

**Federation NOT probed — 4.49944/310 row UNCHANGED** per iter472-497 directive. r22 §13.x federation guardrails not touched.

---

## Verification confirmations

**A. Q1 CUBE/GROUPING re-probe HELD** — CUBE(region, product) emits all four GROUPING values 0/1/2/3; WHEN 2 = product-only subtotal is correct under CUBE; WHEN 3 = grand total is correct. Responder did NOT mis-apply the ROLLUP "value 2 never appears" rule to CUBE. iter496 GROUPING canonical bulletproofing extended successfully to the CUBE angle. **Re-probe CONFIRMED PASS.**

**B. Q3 MERGE TWO SPARK-ISMS CONFIRMED**:
  1. `SET TBLPROPERTIES ('format-version'='2')` is Spark/Hive — Trino requires `SET PROPERTIES format_version = 2` (bare identifier + integer literal). Also Trino-native Iceberg tables already default to format_version 2.
  2. `WHEN MATCHED THEN UPDATE SET *` / `WHEN NOT MATCHED THEN INSERT *` wildcards are Spark/Databricks-Delta — Trino requires explicit `UPDATE SET (col = expr, ...)` and `INSERT (col_list) VALUES (...)`.
Both verified against trino.io/docs/current/sql/merge.html, trino.io/docs/current/connector/iceberg.html, trino.io/docs/current/sql/alter-table.html.

**C. Q4 Oracle (+) mapping CORRECT** — (+) preserves the side OPPOSITE to it; `a.id = b.id(+)` = LEFT JOIN; `a.id(+) = b.id` = RIGHT JOIN. Side-dependent answer is correct.

---

## Concrete next-teacher actions (HIGH priority for iter498)

1. **HIGH — Install a r27 §3.2 (or r28 MERGE subdomain) LEADING CANONICAL block for Trino MERGE INTO** — this is the highest-priority fix because the Spark-ism class slipped twice in the same answer. The block must contain:
   - **Leading canonical Trino MERGE example** with EXPLICIT column assignments (full CDC upsert pattern showing `WHEN MATCHED AND s.op = 'DELETE' THEN DELETE`, `WHEN MATCHED THEN UPDATE SET col1 = s.col1, col2 = s.col2`, `WHEN NOT MATCHED THEN INSERT (col1, col2) VALUES (s.col1, s.col2)`).
   - **DO-NOT-WRITE banner** listing both Spark-isms by name with parse-error annotations:
     - DO NOT WRITE: `UPDATE SET *` (Spark/Databricks-Delta wildcard — Trino MERGE has no wildcard form, requires explicit column list per trino.io/docs/current/sql/merge.html).
     - DO NOT WRITE: `INSERT *` (same — Spark-only).
     - DO NOT WRITE: `ALTER TABLE ... SET TBLPROPERTIES ('format-version' = '2')` (Spark/Hive syntax — Trino uses `SET PROPERTIES format_version = 2` per trino.io/docs/current/sql/alter-table.html + iceberg connector docs).
   - **Format-version default callout**: Trino-created Iceberg tables default to format_version 2 (verbatim quote from trino.io/docs/current/connector/iceberg.html: "Defaults to 2."). The upgrade ALTER is ONLY needed for tables migrated in from Hive or other engines that defaulted to v1.
   - **Cross-link from the Postgres-to-Iceberg CDC subdomain in r16/r17** so the responder finds this block via "CDC upsert" / "MERGE" / "Iceberg merge" / "row-level update" keyword routing.

2. **MEDIUM — Reconcile any other resources/ files that show the Spark dialect forms.** Grep for:
   - `SET TBLPROPERTIES` across all resources/ files.
   - `UPDATE SET \*` and `INSERT \*` across all resources/ files.
   - If any other resource shows these forms even as a Spark contrast, ensure each is tagged as Spark-only with a "Trino equivalent: ..." sibling. Per the reconcile-don't-append rule: fix in place, don't just add a new block.

3. **LOW — r28 §LEADING CANONICAL GROUPING block extension confirmed effective.** No further action on the CUBE/ROLLUP canonical this iter — iter497 enhancement pattern-matched verbatim. Leave the (a)-(g) layout as-is.

---

## Judge probe targets for iter498

1. **MERGE RE-PROBE (HIGH priority)** — re-probe MERGE INTO on Iceberg from a DIFFERENT keyword phrasing (e.g., "I have a Trino MERGE statement that errors on `SET *` — what's the right form?" or "How do I write an idempotent upsert from a staging table into iceberg.analytics.fact_orders with these columns?"). Confirm BOTH Spark-isms purged.
2. **format_version probe** — ask "Do I need to ALTER TABLE format_version on a fresh Trino-created Iceberg table before I can MERGE into it?" to test whether the "defaults to 2" fix landed.
3. **CUBE angle 2nd probe** — ask a CUBE(a, b, c) 3-column question to confirm the canonical generalizes to 2^3 = 8 emitted values (0/1/2/3/4/5/6/7) cleanly under CUBE while ROLLUP(a,b,c) stays at 0/1/3/7.
4. **Federation NOT probed** — per iter472-497 directive, leave federation alone (4.49944/310 row UNCHANGED).
5. **Oracle migration second-angle** — re-probe (+) outer join from a different angle (e.g., "self outer join with (+)" or "multi-table (+)" — Oracle's (+) does not allow OR conditions and is limited to one side per join; could test if responder knows these limitations).

---

## Iteration meta

- **96th consecutive overall PASS in extended phase**; margin +0.828 above 3.5 floor.
- Q3 FAIL is the FIRST significant accuracy fail since iter495 Q4 (GROUPING bitmask, since fixed) — pattern shows that single-question dialect slips still appear when a topic lacks a leading-canonical bulletproofing block.
- Q1 CUBE re-probe extends the leading-canonical-bulletproofing streak to **6 successful instances** (r13 Spark writeTo iter420; r07 GROUP-BY-expression iter485; r07 §5 YoY Pattern B2 iter493; r27 §4.1A DECODE-NULL iter494; r28 LEADING CANONICAL GROUPING iter496; r28 GROUPING extension to CUBE-angle iter497).
- training/state.json NOT bumped per directive (teacher set it to 497; left intact).
