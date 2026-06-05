# Iter 499 Judge Feedback — 2026-06-06 (EXTENDED PHASE)

## Headline

**OVERALL = 4.4219 PASS** (+0.9219 above 3.5 floor). **BOTH iter498 fabs CONFIRMED FIXED** — Q1 Trino-no-index re-probe is clean (responder explicitly stated "Trino + Iceberg has NO user-creatable secondary indexes — no CREATE INDEX, no ADD INDEX, no implicit indexing from PRIMARY KEY") and Q2 dbt-view-storage re-probe is clean (responder explicitly stated "dbt views do NOT store anything ... zero bytes sit in MinIO"). Q3 LISTAGG fully dialect-correct. **Q4 dbt snapshot SCD2 is a FINDABILITY GAP, NOT a content gap** — complete correct content already exists in r09 §1a/1b (lines 350-423) but responder consulted r10/r25/r27/r23 and PUNTED. Federation NOT probed (per directive).

---

## Q1 — Trino index re-probe ("how to CREATE INDEX in Trino/Iceberg?") — **4.9375 STRONG PASS — ITER498 FAB #2 FIXED**

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | "Trino + Iceberg has NO user-creatable secondary indexes — no CREATE INDEX, no ADD INDEX, no implicit indexing from PRIMARY KEY" verified at trino.io/docs/current/connector/iceberg.html — Iceberg connector exposes NO CREATE INDEX surface. The four levers offered are exactly the correct filter-speed mechanisms: (1) partition pruning via partition spec including `bucket(customer_id, N)` — verified at trino.io Iceberg connector "Partitioned tables" section (year/month/day/hour/bucket/truncate transforms); (2) `sorted_by = ARRAY['customer_id','status']` + `ALTER TABLE ... EXECUTE optimize` for Parquet file min/max data skipping — verified in Iceberg connector "Sorted tables" section; (3) `ANALYZE iceberg.analytics.events` for CBO stats (bare ANALYZE, no TABLE keyword) — Trino 467 dialect-correct; (4) optional Parquet bloom filters via `parquet_bloom_filter_columns` table property — verified at trino.io. EXPLAIN to confirm pruning is the canonical Trino verification path. |
| Clarity | 4.75 | Postgres CREATE INDEX → Trino "no equivalent" pivot is clear; four-lever menu is well-organized; -0.25 because could have surfaced ONE worked example (CREATE TABLE WITH partitioning+sorted_by) to anchor copy-paste. |
| Actionability | 5.0 | Engineer knows exactly: stop looking for CREATE INDEX; use partition spec for `customer_id` bucketing; use `sorted_by` for `status` clustering; run ANALYZE; verify with EXPLAIN. Zero translation work. |
| Completeness | 5.0 | All four mechanisms covered + the negative ("no CREATE INDEX/ADD INDEX/PRIMARY KEY indexing") explicit + verification path. |

**Q1 = (5.0 + 4.75 + 5.0 + 5.0) / 4 = 4.9375 STRONG PASS — ITER498 FAB #2 FIXED**

**EXPLICIT CONFIRMATION — Iter498 Q4 "Trino tables/views CAN BE INDEXED" fab DID NOT RECUR**: the responder this iteration explicitly stated the opposite ("NO user-creatable secondary indexes — no CREATE INDEX, no ADD INDEX, no implicit indexing from PRIMARY KEY"), which is the canonical r03 §LEADING CANONICAL block content the iter499 teacher installed. The leading-canonical block pattern-matched verbatim. **7th successful instance of leading-canonical-example bulletproofing**.

---

## Q2 — dbt view-cost re-probe ("do materialized=view models eat MinIO storage?") — **4.8125 STRONG PASS — ITER498 FAB #1 FIXED**

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 4.75 | Core claim "dbt views do NOT store anything ... zero bytes sit in MinIO" verified at docs.getdbt.com/docs/build/materializations — a dbt `view` materialization registers a database VIEW (stored SELECT definition only, no row data), and metadata lives in Hive Metastore, not MinIO data files. Re-execution-on-read mechanic correct. Option A `materialized='table'` correct. Option B Trino MATERIALIZED VIEW syntax verified at trino.io/docs/current/sql/create-materialized-view.html — `CREATE [OR REPLACE] MATERIALIZED VIEW name [GRACE PERIOD interval] [WHEN STALE (INLINE\|FAIL)] [WITH properties] AS query` — answer's `CREATE MATERIALIZED VIEW iceberg.analytics.dashboard_events GRACE PERIOD INTERVAL '90' MINUTE WITH (partitioning=ARRAY['event_date']) AS SELECT ...` is dialect-valid (GRACE PERIOD + WITH ordering correct; INTERVAL '90' MINUTE syntax valid). `REFRESH MATERIALIZED VIEW <name>` bare form is correct per trino.io/docs/current/sql/refresh-materialized-view.html (no extra args). Iceberg connector auto-creates a hidden storage table per MV verified at trino.io/docs/current/connector/iceberg.html ("Each materialized view consists of a view definition and an Iceberg storage table"). -0.25 because the answer did not mention the optional `WHEN STALE (INLINE\|FAIL)` clause that controls stale-MV fallback behavior — non-load-bearing but completes the GRACE PERIOD picture (stale MV either falls back to inline query or fails). |
| Clarity | 4.75 | view vs table vs MV three-way decision is clean; rule-of-thumb (when to use which) is concrete. |
| Actionability | 5.0 | Engineer knows: keep view if cheap-to-rerun; switch to `materialized='table'` if dashboard is hot; use MV with GRACE PERIOD if engine-managed staleness acceptable. Copy-pasteable DDL. |
| Completeness | 4.75 | Three materializations covered + decision criterion + DDL forms. -0.25 for missing WHEN STALE clause completeness. |

**Q2 = (4.75 + 4.75 + 5.0 + 4.75) / 4 = 4.8125 STRONG PASS — ITER498 FAB #1 FIXED**

**EXPLICIT CONFIRMATION — Iter498 Q4 "dbt view creates persistent table / takes up storage" fab DID NOT RECUR**: the responder this iteration explicitly stated the opposite ("dbt views do NOT store anything ... zero bytes sit in MinIO ... view def registered in Hive Metastore, every read re-executes the SELECT"), which is the canonical r28 §3.3 LEADING CANONICAL block content the iter499 teacher installed. The leading-canonical block pattern-matched verbatim. **8th successful instance of leading-canonical-example bulletproofing**.

---

## Q3 — Oracle LISTAGG → Trino equivalent (with ORDER BY) — **4.8125 STRONG PASS**

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 4.75 | (i) Trino `listagg(expr, sep) WITHIN GROUP (ORDER BY ...)` syntax verified at trino.io/docs/current/functions/aggregate.html — supported since Trino 396. (ii) `ON OVERFLOW {ERROR \| TRUNCATE filler {WITH\|WITHOUT} COUNT}` clause verified at same page — Trino BNF matches answer verbatim. (iii) 1,048,576-byte (1 MiB) per-row limit verified at same docs page (default overflow behavior is ERROR if length exceeds 1048576 bytes). (iv) listagg is aggregate-only with NO `OVER()` window form verified at same docs page ("The current implementation of listagg function does not support window frames"); workaround `array_join(array_agg(...) OVER(...), ', ')` is dialect-valid and the correct escape hatch. -0.25 for the "syntax identical to Oracle" phrasing being slightly overstated — Trino's 1 MiB per-row vs Oracle's 4000-byte VARCHAR2 / 32767-byte VARCHAR2 ceiling IS a real divergence (the answer flagged it but the lede phrasing oversells equivalence). |
| Clarity | 4.75 | Three-part structure (basic syntax / ON OVERFLOW / window-form workaround) is clean; Oracle-vs-Trino size-limit contrast is concrete. |
| Actionability | 5.0 | Engineer can drop the Oracle LISTAGG into Trino verbatim with WITHIN GROUP (ORDER BY ...) and it parses; knows to use array_join+array_agg+OVER if windowed LISTAGG was used; knows to size-check against 1 MiB cap. |
| Completeness | 4.75 | Aggregate form + ORDER BY + ON OVERFLOW + size limit + window-form workaround all covered. |

**Q3 = (4.75 + 4.75 + 5.0 + 4.75) / 4 = 4.8125 STRONG PASS**

---

## Q4 — dbt snapshot SCD2 timestamp vs check strategy — **3.125 FAIL — FINDABILITY GAP (content exists in r09 §1a/1b, responder did not route there)**

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 3.5 | The inferred portion is **directionally correct** — verified at docs.getdbt.com/docs/build/snapshots: "Timestamp — which uses an updated_at column to determine if a row has changed, and Check — which compares a list of columns between their current and historical values"; and "check_cols ... it is better to explicitly enumerate the columns that you want to check" (avoids spurious version rows from unrelated column updates). BUT the responder delivered NO config keys (`strategy='timestamp'` requires `updated_at='<col>'`; `strategy='check'` requires `check_cols` as a list OR bare string `'all'`), NO `dbt_valid_from`/`dbt_valid_to` mechanics, NO DO-NOT-WRITE matrix. Inference without specifics is incomplete information, not full accuracy. |
| Clarity | 4.0 | What it DID say was clearly worded. -1.0 because punting itself is a clarity problem — the engineer asked a concrete question and got a partial conceptual answer with a "go read external docs" deflection. |
| Actionability | 2.5 | Engineer cannot act: no config keys to copy, no DDL example, no current-rows query pattern (`WHERE dbt_valid_to IS NULL`), no warning about the `check_cols=['all']` list-wrapping trap. Told to consult external dbt docs when the answer is in-repo. |
| Completeness | 2.5 | Strategy-name comparison present but the bulk of what r09 §1a/1b carries — config keys, metadata columns, current-row query, DO-NOT-WRITE banners — entirely missing. |

**Q4 = (3.5 + 4.0 + 2.5 + 2.5) / 4 = 3.125 FAIL**

**FINDABILITY-GAP FINDING (LOAD-BEARING for iter500 teacher)**: I verified that **complete, correct dbt-snapshot SCD2 content already exists** at `resources/09-lakehouse-schema-design.md` lines 350-423, covering:
- §1a `strategy='timestamp'` with required `updated_at='<col>'` config key + worked example
- §1b `strategy='check'` with required `check_cols=['col1','col2',...]` LIST form OR bare string `'all'` shorthand + worked example
- All four metadata columns (`dbt_valid_from`, `dbt_valid_to`, `dbt_is_deleted` in 1.9+, `dbt_scd_id`) and the `WHERE dbt_valid_to IS NULL` current-rows query pattern
- DO-NOT-WRITE banners banning: fake strategies (`hash`/`merge`/`changes`), fake config keys (`compare_cols`/`monitor_cols`/`watch_cols`/`track_cols`/`updated_at_field`/`last_modified_column`), `check_cols=['all']` list-wrapping, fake `dbt_is_current` column

The r09 §1a/1b content itself is technically correct vs docs.getdbt.com/docs/build/snapshots + docs.getdbt.com/reference/resource-configs/check_cols (both verified this iter). The responder consulted r10/r25/r27/r23 and never landed at r09. **This is a keyword-routing failure, NOT a content gap. Iter500 teacher fix must be a FINDABILITY fix — DO NOT write new content.**

---

## Overall: **4.4219 PASS** (98th consecutive overall PASS in extended phase)

| Q | Topic | Score | Notes |
|---|---|---|---|
| Q1 | Query performance basics: partitioning, indexing strategy | 4.9375 | ITER498 FAB #2 FIXED |
| Q2 | Improving complex SQL performance on Trino with dbt | 4.8125 | ITER498 FAB #1 FIXED |
| Q3 | Oracle PL/SQL → dbt/Trino migration | 4.8125 | LISTAGG fully dialect-correct |
| Q4 | dbt snapshots SCD2 | 3.125 | FINDABILITY GAP — content exists in r09, not routed |

**Average = (4.9375 + 4.8125 + 4.8125 + 3.125) / 4 = 17.6875 / 4 = 4.4219 PASS** (+0.9219 above 3.5 floor).

**Topic average updates**:
- *Query performance basics: partitioning, indexing strategy for analytics* (Q1 maps here) 4.3164/18 → (4.3164*18 + 4.9375)/19 = 82.6327/19 = **4.3491/19** (+0.0327)
- *Improving complex SQL performance on Trino with dbt* (Q2 maps here) 4.5612/10 → (4.5612*10 + 4.8125)/11 = 50.4245/11 = **4.5840/11** (+0.0228)
- *Oracle PL/SQL→dbt/Trino migration* (Q3 maps here) 4.5310/70 → (4.5310*70 + 4.8125)/71 = 321.9825/71 = **4.5350/71** (+0.0040)
- *dbt snapshots SCD2* (Q4 maps here) 4.5625/2 → (4.5625*2 + 3.125)/3 = 12.25/3 = **4.0833/3** (-0.4792 — Q4 FAIL drags meaningfully on the low-sample-count row but still PASS, above 3.5 floor)

**Federation NOT probed — 4.49944/310 row UNCHANGED per iter472-499 directive.** Per the user-supplied directive, §13.x federation guardrails in r22 untouched; federation rubric row stays 4.49944/310.

---

## Concrete next-teacher actions for iter500 (FINDABILITY FIX, NOT NEW CONTENT)

The content for Q4 already exists at `resources/09-lakehouse-schema-design.md` §1a/1b (lines 350-423). The fix is to make it findable from the keyword routes the responder actually walks.

1. **Add keyword anchors in r09** at the section header so phrases like "dbt snapshot", "SCD2 strategy", "timestamp vs check strategy", "check_cols", "snapshot strategy", "Customer SCD2", "tracked columns", "plan_tier status snapshot" route to §1a/1b. The current section header may not contain enough surface keywords for a Haiku responder doing keyword→resource matching.
2. **Forward-pointer block from r27 (Oracle PL/SQL→dbt/Trino migration) dbt section to r09 §1a/1b** — the responder consulted r27 for this question. Add a one-paragraph "dbt snapshot SCD2 for migrated dimensions → see r09 §1a/1b for strategy=timestamp / strategy=check config keys, metadata columns, and DO-NOT-WRITE matrix".
3. **Forward-pointer block from r28 (Improving complex SQL performance on Trino with dbt) dbt section to r09 §1a/1b** — same reasoning; r28 covers dbt materializations but not snapshots; a one-line cross-ref prevents the next snapshot probe from punting.
4. **Forward-pointer block from r10 (lakehouse-partitioning) and r23 (sql-best-practices-olap) dbt-related sections to r09 §1a/1b** — the responder also consulted r10 and r23 and missed.
5. **Do NOT write a new snapshot block elsewhere.** The r09 content is canonical and correct. Adding a duplicate elsewhere risks creating contradictory blocks (the iter495 dbt-trino partitioning-key stale-block problem). Add ONLY cross-refs and keyword anchors.

While installing cross-refs, verify (already verified by judge this iter against docs.getdbt.com) that r09 §1a/1b content is still correct against current dbt docs — it is.

**Optional non-blocking polish for the other answers**:
- Q2 could add a one-line "optional `WHEN STALE (INLINE | FAIL)` clause" note to the MV section in r28 §3.3 — non-load-bearing, but completes the GRACE PERIOD story.
- Q3 LISTAGG "identical to Oracle" lede could be softened to "syntactically equivalent; size limit differs (Trino 1 MiB vs Oracle 4000/32767 bytes)" — already flagged in answer body, just hoist to the lede.

---

## Iter500 judge probe targets

| Priority | Probe | Rationale |
|---|---|---|
| **HIGH** | dbt snapshot SCD2 from a 3rd phrasing angle (e.g., "how do I track historical changes to my Customer dim?" or "dbt snapshot config for a slowly-changing dim with updated_at column") | Confirm iter500 findability fix routes from a different keyword set than this iter's "timestamp vs check strategy" phrasing; topic just dropped to 4.0833/3 and needs the re-probe to recover |
| **HIGH** | Trino-no-index re-probe from a 3rd phrasing angle (e.g., "Iceberg performance — should I add an index on customer_id?" or "Trino slow filter — how do I add an index?") | iter498 fab fixed, iter499 fix landed, but topic is only 4.3491/19 — needs continued bulletproofing to push above 4.5 |
| MEDIUM | dbt view-storage re-probe from a 3rd phrasing angle ("does materialized=view in dbt-trino write any data?" or "how much storage does my dbt view model use?") | iter498 fab fixed, iter499 fix landed; one more clean probe consolidates the fix |
| MEDIUM | LISTAGG with FILTER (WHERE) clause OR LISTAGG with NULL-handling probe | Test deeper LISTAGG dialect knowledge beyond basic ORDER BY |
| MEDIUM | Trino MATERIALIZED VIEW `WHEN STALE` clause probe | Tests the MV completeness gap flagged in Q2 |
| LOW | Snapshot `dbt_is_deleted` 1.9+ behavior probe | Tests deeper dbt snapshot knowledge after findability fix lands |
| **DO NOT PROBE** | Federation / cross-source / PostgreSQL connector / predicate pushdown | r22 §13.x guardrails not touched per iter472-499 directive; row stays 4.49944/310 |

---

## Summary

**OVERALL = 4.4219 PASS**. Both iter498 fabs **CONFIRMED FIXED** — leading-canonical pattern-matching worked for both Q1 (no-index) and Q2 (view-storage). Q3 LISTAGG fully dialect-correct. Q4 dbt snapshot SCD2 is a **FINDABILITY GAP**, not a content gap — the answer is already in r09 §1a/1b lines 350-423; iter500 must install keyword anchors + cross-references from r10/r23/r27/r28 to r09, NOT write new content. Federation untouched per directive.
