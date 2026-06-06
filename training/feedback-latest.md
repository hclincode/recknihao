# Iter 518 Judge Feedback — 2026-06-06 (EXTENDED PHASE)

## Overall: 4.5469 PASS — but with a NEW fabrication on Q2

**Score**: (Q1 4.9375 + Q2 3.8125 + Q3 4.625 + Q4 4.8125)/4 = **18.1875 / 4 = 4.5469 PASS** (+1.0469 above 3.5 floor; weakest margin in recent 9-iter window, dragged by Q2 new-fab nit).

**Iter517 fix landing status**:
- **FIX A (r07 §1a.3 array `contains` canonical) — FULLY LANDED on Q1.** Responder uses `contains(roles, 'admin')` boolean, cardinality, array_distinct — the iter517 Q2 "Trino has no contains" fabrication is GONE.
- **FIX B (r17 leading canonical — THREE setters for Iceberg target file size) — PARTIALLY LANDED on Q2.** The `spark.sql.iceberg.write.target-file-size-bytes` session-config fab from iter517 Q3 is GONE (responder explicitly debunks it). BUT a NEW related fabrication appeared: `write_target_file_size_bytes` as a Trino DDL `WITH (...)` table-property name — see Section B below.

---

## Per-question scores

### Q1 — array roles membership / count / dedup — **4.9375 STRONG PASS**

| Dim | Score | Reason |
|---|---|---|
| Accuracy | 5.0 | `contains(roles, 'admin')` boolean, `cardinality(roles)`, `array_distinct(roles)`, `cardinality(array_distinct(roles))` ALL verified verbatim at trino.io/docs/current/functions/array.html. No UNNEST-for-membership, no fabrication. |
| Clarity | 5.0 | Clean boolean-vs-UNNEST routing; explicit "no UNNEST needed for membership". |
| Actionability | 5.0 | Engineer can paste `WHERE contains(roles, 'admin')` directly. |
| Completeness | 4.75 | -0.25 for no callout that `contains` does NOT work on MAPs (for MAP key existence use `element_at(map, key) IS NOT NULL`) — minor cross-ref gap. |

**Verification (doc quote)**: trino.io/docs/current/functions/array.html — `contains(x, element) → boolean`: "Returns true if the array `x` contains the `element`." `cardinality(x) → bigint`: "Returns the cardinality (size) of the array." `array_distinct(x) → array`: "Remove duplicate values."

**ITER518 r07 §1a.3 ARRAY CANONICAL LANDED.** The iter517 responder fab "Trino has no single CONTAINS function" is fully reconciled. 21st leading-canonical-bulletproofing instance to land cleanly on first re-probe.

---

### Q2 — Iceberg target file size table property / session config — **3.8125 BARELY PASS** (NEW FAB)

| Dim | Score | Reason |
|---|---|---|
| Accuracy | 3.0 | **Iter517 session-config fab GONE** (good — `spark.sql.iceberg.target-file-size` correctly debunked as "not the canonical approach"). **BUT NEW FAB**: the DDL `CREATE TABLE ... WITH (write_target_file_size_bytes = 268435456)` invents an underscore-flattened Trino table property that does NOT exist on Trino 467. The Trino Iceberg connector's documented `WITH (...)` table-properties list does NOT include `write_target_file_size_bytes` — verified by WebFetch of trino.io/docs/current/connector/iceberg.html. Per Trino GitHub issue #28250 (opened 2026-02-11, PR #28057), this is a **"Proposed Enhancement"** still pending merge: "convert the session properties to Iceberg's native table properties for write configuration" — NOT available on Trino 467. -2.0 for inventing a non-existent flat WITH-clause property. |
| Clarity | 4.5 | Clean prose; correctly explains "table property, not session config" routing. -0.5 because the user is given a property name they will get a parse error on. |
| Actionability | 3.5 | The compaction half (Spark `rewrite_data_files` + Trino `EXECUTE optimize(file_size_threshold => '256MB')`) is correct and usable. But the headline DDL `WITH (write_target_file_size_bytes = ...)` will fail at parse/validation time — engineer cannot paste it. -1.5 for the broken-on-paste DDL. |
| Completeness | 4.25 | Discusses compaction + session-vs-table-property framing well. -0.75 for not listing the three ACTUAL valid setters on Trino 467: (1) `extra_properties = map(ARRAY['write.target-file-size-bytes'], ARRAY['268435456'])` at CREATE TABLE — the ONLY way to set the native Iceberg property from Trino DDL today; (2) Spark `ALTER TABLE … SET TBLPROPERTIES('write.target-file-size-bytes' = '268435456')`; (3) cluster-wide Trino catalog config `iceberg.target-max-file-size` in `etc/catalog/iceberg.properties` (default 1 GB) + session-form `SET SESSION iceberg.target_max_file_size = '256MB'`. |

**Verification (doc quotes + sources)**:
- **trino.io/docs/current/connector/iceberg.html table-properties list (WebFetched)**: confirmed properties include `format`, `compression_codec`, `partitioning`, `sorted_by`, `location`, `format_version`, `max_commit_retry`, `delete_after_commit_enabled`, `max_previous_versions`, `orc_bloom_filter_columns`, `orc_bloom_filter_fpp`, `parquet_bloom_filter_columns`, `object_store_layout_enabled`, `data_location`, `extra_properties`. **`write_target_file_size_bytes` is NOT in the list.**
- **GitHub trinodb/trino #28250 (WebFetched)**: "Proposed Enhancement" + PR #28057 pending — `write.target-file-size-bytes` as a directly settable Trino table property is NOT yet merged into Trino 467. Quote: "the implementation is pending in PR #28057... Currently, Trino only supports session-level configuration through properties like `target_max_file_size` rather than persisted table properties."
- **trino.io extra_properties doc**: "Additional properties added to an Iceberg table" — this IS the documented mechanism for setting native Iceberg properties from Trino DDL.

**ITER518 r17 FIX B PARTIALLY LANDED.** The exact iter517 fab `spark.sql.iceberg.write.target-file-size-bytes` Spark session config is GONE (responder explicitly debunks the `spark.sql.iceberg.*` family — that part of FIX B reached the responder). But the responder substituted a NEW underscore-flattened Trino-property fab in its place. The r17 LEADING CANONICAL block needs a tighter DO-NOT-WRITE call-out specifically against the underscore-flat Trino DDL form `write_target_file_size_bytes` AND a verbatim **`extra_properties = map(ARRAY['write.target-file-size-bytes'], ARRAY['268435456'])`** Trino-DDL example as the leading-canonical Trino-side answer (currently the r17 block routes Trino users only to the catalog config + session property, missing the per-table extra_properties form).

---

### Q3 — Oracle ROWID dedup → Trino — **4.625 PASS** (messy first query)

| Dim | Score | Reason |
|---|---|---|
| Accuracy | 4.5 | Second query is the canonical Trino 467 dedup idiom: `ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY created_at) AS rn` → outer `WHERE rn = 1` — verified correct (Trino 467 has NO QUALIFY, window functions cannot be used in WHERE, so subquery/CTE form is mandatory). Correctly states "Trino has no ROWID". -0.5 for the FIRST query which references undefined columns (`id_within_group`, `row_id`, `min_id` alias mismatch) — the inner SELECT aliases `FIRST_VALUE(row_id) ... AS min_id` but the outer NOT IN matches on `(customer_id, id_within_group)` against `(customer_id, min_id)` — column names don't align with the input table, query is non-runnable. |
| Clarity | 4.5 | Second/idiomatic query is clear. -0.5 because the messy first query confuses readers (does it work? what's `id_within_group`?). |
| Actionability | 4.5 | Engineer can paste the second query. -0.5 for not addressing the IN-PLACE DELETE form the user asked about — Oracle's `DELETE WHERE ROWID NOT IN (...)` mutates in place. The canonical Iceberg-via-Trino rowid-free replacement is **CTAS + RENAME** (`CREATE TABLE t_new AS SELECT * FROM (SELECT *, ROW_NUMBER() OVER (...) rn FROM t) WHERE rn=1; ALTER TABLE t RENAME TO t_old; ALTER TABLE t_new RENAME TO t;`) OR a `MERGE` (delete branch for rn>1) — neither is shown. A bare DELETE keep-min-per-group has no clean rowid-free shape; that fact should be stated. |
| Completeness | 5.0 | Covers the keep-first-per-group semantics + PARTITION BY customer_id + ORDER BY created_at — the core question. |

**Verification**:
- trino.io/docs/current/sql/select.html — no QUALIFY clause in Trino 467 grammar; window function in WHERE causes parse error → subquery/CTE form is mandatory.
- GitHub trinodb/trino discussion #15481 "For Iceberg, delete duplication rows within the table" — confirms canonical Iceberg dedup pattern in Trino is recreate-via-CTAS or MERGE (not bare DELETE).

---

### Q4 — dbt incremental composite unique_key — **4.8125 STRONG PASS** (minor nit)

| Dim | Score | Reason |
|---|---|---|
| Accuracy | 4.75 | `unique_key=['customer_id', 'event_date']` list form is the canonical dbt composite-key syntax (introduced dbt-core 1.1.0+) — verified at docs.getdbt.com/reference/resource-configs/unique_key. dbt-trino generates `MERGE ... ON (t.customer_id = s.customer_id AND t.event_date = s.event_date)` is correct. First-run CTAS / subsequent MERGE upsert lifecycle correct. -0.25 NIT: the example config shows `format_version = 2` as a bare top-level `config()` kwarg. For dbt-trino, Iceberg table properties (including `format_version`, `partitioning`, `sorted_by`) belong inside the `properties={...}` dict, not as top-level `config()` kwargs — per docs.getdbt.com/reference/resource-configs/trino-configs and the iter495 dbt-trino partitioning-key canonical at r05. Correct form: `config(materialized='incremental', unique_key=['customer_id', 'event_date'], properties={'format_version': "'2'", 'partitioning': "ARRAY['day(event_date)']"})`. |
| Clarity | 5.0 | Clean MERGE-ON explanation; well-routed first-run vs subsequent-run semantics. |
| Actionability | 4.5 | Engineer can paste the unique_key list directly. -0.5 because if they copy the `format_version=2` top-level kwarg form, dbt-trino will silently ignore it (or warn) — they won't get format_version=2 on their table. |
| Completeness | 5.0 | Covers list shape + generated MERGE + first-run CTAS routing — the core question. |

**Verification (doc quote)**: docs.getdbt.com/reference/resource-configs/unique_key — "supplied as a string representing a single column or a list of single-quoted column names like `['col1', 'col2', …]`"; dbt-core issue #3431 confirms composite-key list form merged for dbt-core 1.1.0+. dbt-trino issue #465 confirms composite MERGE ON generated correctly when list passed.

---

## Topic rubric updates (iter518)

(Federation row UNTOUCHED per directive — 4.49944/310 stays.)

- **SQL query best practices for OLAP** (Q1 array contains + Q3 ROW_NUMBER dedup map here):
  prior 4.5715/64 → (4.5715·64 + 4.9375 + 4.625)/66 = (292.576 + 9.5625)/66 = **4.5779/66** (+0.0064).
- **Iceberg table maintenance** (Q2 target file size maps here):
  prior 4.4920/155 → (4.4920·155 + 3.8125)/156 = (696.260 + 3.8125)/156 = **4.4877/156** (−0.0043).
- **Oracle PL/SQL → dbt + Trino SQL migration** (Q3 ROWID dedup + Q4 dbt composite unique_key map here):
  prior 4.5448/77 → (4.5448·77 + 4.625 + 4.8125)/79 = (349.949 + 9.4375)/79 = **4.5491/79** (+0.0043).

Topic rubric line to append:
```
Iter518 — 2026-06-06 — overall 4.5469 PASS — Q1 array contains 4.9375 STRONG PASS (iter518 r07 §1a.3 canonical LANDED), Q2 Iceberg target file size 3.8125 BARELY PASS (iter517 session-config fab GONE but NEW write_target_file_size_bytes WITH-clause fab — r17 LEADING CANONICAL block needs underscore-flat DO-NOT-WRITE row + verbatim extra_properties Trino-DDL example), Q3 ROWID dedup 4.625 PASS (canonical ROW_NUMBER subquery correct; messy first query w/ undefined columns + in-place DELETE form not addressed), Q4 dbt composite unique_key 4.8125 STRONG PASS (list form correct; minor nit on format_version-as-top-level-kwarg vs properties={} dict). Federation NOT probed (4.49944/310 stays).
```

---

## Next-teacher actions for iter519 (HIGH-priority first)

1. **HIGH — r17 LEADING CANONICAL block (iter518 FIX B target-file-size canonical) — add Trino-DDL `extra_properties` verbatim example + tighten DO-NOT-WRITE.** Current block lists THREE setters: TBL PROPERTY (Spark form), DataFrameWriter OPTION (Spark form), Trino CATALOG config / session property. **MISSING**: an explicit Trino-DDL example showing how to set the native `write.target-file-size-bytes` property AT CREATE/ALTER TABLE time from Trino. The canonical form is:
   ```sql
   CREATE TABLE iceberg.analytics.events (...)
   WITH (
     format_version = 2,
     partitioning = ARRAY['day(occurred_at)'],
     extra_properties = map(ARRAY['write.target-file-size-bytes'], ARRAY['268435456'])
   )
   ```
   AND extend the DO-NOT-WRITE table with a new banned shape: `write_target_file_size_bytes = 268435456` as a bare WITH-clause kwarg — call out "underscore-flattening of the native dotted `write.target-file-size-bytes` does NOT make it a valid Trino table-property name on Trino 467; the connector's allow-list does NOT include it (verified trino.io/docs/current/connector/iceberg.html); use `extra_properties = map(...)` form" + cite GitHub trinodb/trino #28250 / PR #28057 as the pending feature that would change this in a future Trino release.

2. **HIGH — r27 (Oracle migration) or r17 — ROWID-dedup IN-PLACE DELETE canonical.** Existing §4.5/§7A.2 covers the ROW_NUMBER subquery form correctly, but the Oracle `DELETE WHERE ROWID NOT IN (SELECT MIN(ROWID)…GROUP BY key)` mutation-shape has no clean Trino translation. Add a §"Oracle ROWID-DELETE keep-min-per-group → Trino" callout with TWO canonical replacements: (A) **CTAS + RENAME**: `CREATE TABLE t_dedup AS SELECT * FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY created_at) rn FROM t) WHERE rn = 1; ALTER TABLE t RENAME TO t_old; ALTER TABLE t_dedup RENAME TO t;` (B) **MERGE delete branch**: `MERGE INTO t USING (SELECT id_pk FROM (SELECT id_pk, ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY created_at) rn FROM t) WHERE rn > 1) d ON t.id_pk = d.id_pk WHEN MATCHED THEN DELETE;` (requires a stable PK column — call this out). Explicitly state: "a bare DELETE keep-first-per-group has no clean rowid-free Trino form; you MUST recreate or MERGE."

3. **MEDIUM — r27/r28 — dbt-trino `format_version` belongs in `properties={...}` dict, not as top-level config() kwarg.** Add a small reconcile-in-place callout near the dbt-trino model-config canonical: "Iceberg table properties (`format_version`, `partitioning`, `sorted_by`, `write.target-file-size-bytes` via extra_properties) go INSIDE the `properties={...}` dict — NOT as bare `config()` top-level kwargs. dbt-trino routes `properties` through to the underlying Trino `CREATE TABLE … WITH (...)` clause; top-level config() kwargs are dbt-core materialization kwargs only." Show wrong vs right side-by-side.

4. **LOW — r07 §1a.3 — add MAP cross-ref nit.** Add one line: "`contains()` works on ARRAY only — for MAP key existence use `element_at(map, key) IS NOT NULL` (cross-ref r09 §MAP)." Picks up the Q1 -0.25 Completeness gap.

---

## Iter519 probe targets

- **HIGH — Iceberg target-file-size from Trino DDL RE-PROBE**: "On Trino 467, how do I set `write.target-file-size-bytes` to 256MB AT CREATE TABLE time?" — verifies the `extra_properties = map(…)` canonical lands, and that the `write_target_file_size_bytes` flat-property fab does NOT reappear.
- **HIGH — ROWID-dedup IN-PLACE DELETE RE-PROBE**: "Oracle `DELETE FROM customers c WHERE c.ROWID NOT IN (SELECT MIN(ROWID) FROM customers GROUP BY email)` — give me the in-place Trino equivalent." — verifies the CTAS+RENAME or MERGE keep-min canonical lands, and that the "no clean rowid-free DELETE" framing is correctly stated.
- **MEDIUM — dbt-trino properties dict RE-PROBE**: "Show me a dbt-trino incremental model config with `unique_key=['a','b']`, `format_version=2`, and `partitioning=ARRAY['day(ts)']` — where do format_version + partitioning go in the config block?" — verifies properties={...} routing lands.
- **MEDIUM — `contains` on MAP angle**: "Can I use `contains(my_map, 'some_key')` to check MAP key existence?" — tests Q1 §1a.3 MAP-routing cross-ref.
- **LOW — Federation stays UNPROBED** per locked directive.

---

## Pattern notes

- **Iter517 FIX A (contains) LANDED CLEAN; iter517 FIX B (target-file-size) LANDED PARTIAL with NEW FAB SUBSTITUTION.** The teacher's r17 LEADING CANONICAL block correctly killed the Spark session-config fab family but left a hole: it routed users to "TABLE PROPERTY" as a category without showing the Trino-DDL form to actually set the native dotted property. The responder filled that gap by inventing an underscore-flattened Trino property name — a classic "responder confabulates the missing example" failure mode. Lesson: when adding a multi-engine setter canonical, EACH engine needs a verbatim DDL example or the responder will fabricate one. The corresponding `extra_properties = map(ARRAY[...], ARRAY[...])` Trino-DDL example is the missing piece.
- **111th consecutive overall PASS in extended phase, margin +1.0469 above floor — but the THINNEST margin in 9+ iters.** Iter519 with the iter518 Q2 fix landing should restore the ~4.9 margin.
- **22 leading-canonical bulletproofing instances total** (Q1 §1a.3 array_contains is #22); Q2 r17 target-file-size remains incomplete pending the extra_properties Trino-DDL example.
- Federation row 4.49944/310 untouched — confirmed zero edits to resources/22 §13.x.
