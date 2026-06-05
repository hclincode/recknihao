# Iter 498 Judge Feedback — 2026-06-06 (EXTENDED PHASE)

## Headline

**OVERALL = 4.5625 PASS** (+1.0625 above 3.5 floor). Q1 MERGE re-probe FIX **LANDED CLEAN** — the r13 findability fix from the iter498 teacher worked. Q4 dbt view materialization has a **NEW LOAD-BEARING FAB** (view "creates a persistent table / takes up storage" + "CAN BE INDEXED" on Trino) — both wrong, needs corrective canonical. Federation NOT probed (per directive).

---

## Q1 — Trino MERGE re-probe (CDC i/u/d → Iceberg orders) — **4.9375 STRONG PASS — FIX LANDED**

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | MERGE grammar Trino-dialect-correct verbatim. Explicit columns on `UPDATE SET customer_id=s.customer_id, status=s.status, total=s.total, updated_at=s.updated_at` and `INSERT (order_id, customer_id, status, total, updated_at) VALUES (s.order_id, ...)` — NO `UPDATE SET *` / `INSERT *` Spark-isms. Conditional clauses `WHEN MATCHED AND s.op='u'` / `WHEN MATCHED AND s.op='d'` / `WHEN NOT MATCHED AND s.op='i'` valid per trino.io/docs/current/sql/merge.html grammar (BNF allows `AND condition` on each WHEN branch). Setup uses `ALTER TABLE ... SET PROPERTIES format_version = 2` (bare identifier snake_case key + integer literal, NOT Spark's `SET TBLPROPERTIES ('format-version'='2')`) — verified at trino.io/docs/current/connector/iceberg.html. `iceberg.analytics."orders$properties" WHERE key='format-version'` $properties metadata-table check verified — Trino docs explicitly show "format-version | 2" (hyphenated key in the row VALUES, even though the WITH/SET PROPERTIES form uses snake_case `format_version`). Caveat about MERGE producing position-delete files and needing weekly Spark `rewrite_position_delete_files` compaction is correct (no Trino 467 equivalent per Trino iceberg-roadmap issue #27371). |
| Clarity | 4.75 | Explicit-column blocks on both branches make copy-paste safe. Setup-vs-DML clearly separated. -0.25: could have surfaced "Trino-created Iceberg tables default to format_version=2 so the ALTER is only needed for Hive-migrated v1 tables" verbatim to prevent over-applying. |
| Actionability | 5.0 | Engineer can copy MERGE verbatim, run the `$properties` check first, only ALTER if v1, schedule weekly Spark compaction. Zero translation work. |
| Completeness | 5.0 | All three op codes covered, table setup covered, post-MERGE maintenance covered. |

**Q1 = (5.0 + 4.75 + 5.0 + 5.0) / 4 = 4.9375 STRONG PASS — FIX LANDED**

**EXPLICIT CONFIRMATION — Iter497 Q3 Spark-isms DID NOT RECUR**:
- NO `UPDATE SET *` / `INSERT *` star-shorthand (Spark-only — Trino BNF requires explicit column lists)
- NO `SET TBLPROPERTIES ('format-version'='2')` (Spark/Hive form — Trino requires `SET PROPERTIES format_version = 2`)

The r13 §Pattern C ENGINE NOTE callout (added line ~1360) + the inline one-liner at the Pattern B fix (line ~447) + the forward-pointer keywords ("CDC upsert", "MERGE in Trino", "keep Iceberg in sync", "Trino MERGE explicit columns") successfully re-routed the Haiku responder away from r13's Spark MERGE examples and toward r27 §4.6B's Trino canonical. **6th successful instance of findability-fix bulletproofing** (after r13 writeTo iter420, r07 GROUP-BY iter485, r07 §5 YoY iter493, r27 §4.1A DECODE-NULL iter494, r28 GROUPING-bitmask iter496, r28 CUBE-vs-ROLLUP iter497).

---

## Q2 — Oracle MINUS → Trino EXCEPT — **4.875 STRONG PASS**

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | Trino uses `EXCEPT` not `MINUS` — verified at trino.io/docs/current/sql/select.html (MINUS is Oracle-only synonym; Trino + ANSI SQL is EXCEPT). `EXCEPT` is set-distinct (dedup); `EXCEPT ALL` is bag/multiset semantics. Type alignment (CAST `occurred_at AS DATE`) for half-open `[start, end)` Q1/Q2 range filters correct. Q1-but-not-Q2 customers example with `SELECT DISTINCT customer_id ... WHERE occurred_at >= DATE '2026-01-01' AND occurred_at < DATE '2026-04-01' EXCEPT SELECT DISTINCT customer_id ... WHERE occurred_at >= DATE '2026-04-01' AND occurred_at < DATE '2026-07-01'` is dialect-correct and idiomatic. |
| Clarity | 4.75 | EXCEPT vs EXCEPT ALL distinction surfaced. Half-open range pattern explicit. -0.25: could illustrate the type-alignment trap with a concrete failure example (e.g., one column TIMESTAMP one DATE → "different types" error). |
| Actionability | 5.0 | Copy-pasteable; engineer rewrites Oracle MINUS query in one find-replace + handles type cast. |
| Completeness | 4.75 | Covered EXCEPT, EXCEPT ALL, type alignment, half-open ranges. Could mention LEFT JOIN ... WHERE r.x IS NULL as an alternative pattern (sometimes faster on Trino if EXCEPT can't push down). -0.25. |

**Q2 = (5.0 + 4.75 + 5.0 + 4.75) / 4 = 4.875 STRONG PASS**

---

## Q3 — Tiny Parquet file compaction (Trino vs Spark) — **4.875 STRONG PASS**

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | Trino-vs-Spark compaction split CORRECT for 467. Data-file compaction: `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '128MB')` verified at trino.io/docs/current/connector/iceberg.html (verbatim "rewrites table content into fewer but larger files" + file_size_threshold parameter accepts data-size strings). Position-delete-file compaction: `CALL iceberg.system.rewrite_position_delete_files(table => '...')` is a Spark `CALL` procedure per iceberg.apache.org/docs/latest/spark-procedures/ — NOT available as a Trino `EXECUTE` (per Trino issue #27371 "RewritePositionDeleteFiles to Trino similar to Spark's" is on the roadmap, NOT yet shipped in 467). Weekly maintenance ordering (1) Spark rewrite_position_delete_files → (2) Trino EXECUTE optimize → (3) Trino EXECUTE expire_snapshots(retention_threshold => '7d') is operationally sound (rewrite deletes first so optimize sees clean data-files; expire last so snapshots referencing pre-rewrite files can drop). |
| Clarity | 4.75 | Clear engine assignment (Trino does data-file compaction, Spark does position-delete-file compaction). Canonical ordering laid out. -0.25: could clarify that on a write-heavy CDC table, position-delete-file compaction is the load-bearing operation that prevents query slowdown — not just a nice-to-have. |
| Actionability | 5.0 | Engineer knows exactly which engine runs each step + the order. Maps cleanly to the prod stack (Spark for ingestion/maintenance + Trino for queries). |
| Completeness | 4.75 | Covered both file types, both engines, ordering, retention. -0.25: no `min_file_size_bytes` / partition-predicate variant of EXECUTE optimize mentioned (for targeted compaction of hot partitions only). |

**Q3 = (5.0 + 4.75 + 5.0 + 4.75) / 4 = 4.875 STRONG PASS**

---

## Q4 — dbt ephemeral vs view — **3.5625 PASS-AT-FLOOR — NEW LOAD-BEARING FAB**

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 2.5 | **CONFIRMED FAB #1**: "view creates a PERSISTENT TABLE in Trino (takes up storage, queryable directly)" is WRONG. Per docs.getdbt.com/docs/build/materializations: "views store only the SQL logic of the transformation in the warehouse, not the data itself" + "views build almost instantly and cost almost nothing to build" + "they always reflect the most up-to-date version of the input data, as they're run freshly every time they're queried" — a dbt `view` materialization creates a database VIEW (a stored SELECT definition), storing NO row data and negligible storage (just the query text). Calling it a "persistent table that takes up storage" mis-teaches the entire view/table cost model. **CONFIRMED FAB #2**: "CAN BE INDEXED" is fabricated for both Trino views and Trino tables. Trino has NO secondary indexes at all — verified via trino.io/docs/current docs (secondary-index support exists only for niche connectors like Aerospike, Accumulo, Redis, not for the Iceberg connector that the prod stack uses). Trino+Iceberg uses partition pruning + file-skipping via min/max stats + Puffin NDV stats — NOT user-creatable indexes. The "indexed" claim is doubly wrong: views can't be indexed in ANY engine, AND Trino tables can't be indexed either. **CORRECT (credit)**: ephemeral=inlined CTE / not materialized / re-evaluated each time if referenced multiple times / "Trino inlines CTEs". |
| Clarity | 4.0 | Decision table + materialized= config examples are well-structured. The wrong claims are stated confidently and would mislead a beginner. -1.0. |
| Actionability | 3.75 | "Use ephemeral only when referenced once + lightweight; prefer view/table otherwise" is sound directional advice. But the fabricated view-cost-model framing ("storage", "indexed") would push the engineer toward avoiding views for the wrong reasons. -1.25. |
| Completeness | 4.0 | Covers difference, scaling problem, when-to-use each, decision rubric, config syntax. Misses: ephemeral compile-time SQL bloat into downstream models is the actual "problems at scale" failure mode (huge compiled query, planner timeout), not just "re-evaluated each time". -1.0. |

**Q4 = (2.5 + 4.0 + 3.75 + 4.0) / 4 = 3.5625 PASS AT FLOOR**

**CORRECTIONS THE TEACHER MUST INSTALL**:
1. dbt `view` materialization = **database VIEW** (stored SELECT definition). Stores **NO row data**. Storage = negligible (just the query text). Re-executes on every query — cost is **CPU/scan cost at query time**, not storage.
2. Trino has **NO user-creatable secondary indexes** on any object (view OR table). Performance comes from partition pruning + file-skipping (Parquet min/max stats) + Puffin NDV stats. Never tell an engineer to "index" something in Trino.
3. The actual "ephemeral at scale" problem is **compile-time SQL bloat**: ephemeral models get inlined as CTEs in every downstream model, so referencing one ephemeral from N downstreams = N copies of its SQL compiled into N final queries → planner stress, Jinja-compile slowdown, debugging pain (no warehouse object to inspect, no row counts).

---

## Overall iter498

| Metric | Value |
|---|---|
| Q1 MERGE re-probe | 4.9375 STRONG PASS — **FIX LANDED** |
| Q2 Oracle MINUS → EXCEPT | 4.875 STRONG PASS |
| Q3 Tiny Parquet compaction | 4.875 STRONG PASS |
| Q4 dbt ephemeral vs view | 3.5625 PASS AT FLOOR — **NEW LOAD-BEARING FAB** |
| **OVERALL AVG** | **(4.9375 + 4.875 + 4.875 + 3.5625) / 4 = 18.25 / 4 = 4.5625** |
| Pass/Fail | **PASS** (+1.0625 above 3.5 floor) |
| Consecutive PASS in extended phase | **97th** |
| Federation row | 4.49944/310 **UNCHANGED** (NOT probed per directive) |

---

## Topic average updates (per current rubric mapping)

| Topic | Old Avg / N | Q maps | New score | New Avg / N | Δ |
|---|---|---|---|---|---|
| Postgres-to-Iceberg ingestion | 4.4884 / 167 | Q1 MERGE | 4.9375 | (4.4884*167 + 4.9375)/168 = 754.7003/168 = **4.4923 / 168** | +0.0039 |
| Oracle PL/SQL → dbt/Trino migration | 4.5260 / 69 | Q2 MINUS→EXCEPT | 4.875 | (4.5260*69 + 4.875)/70 = 317.1690/70 = **4.5310 / 70** | +0.0050 |
| Iceberg table maintenance | 4.4931 / 148 | Q3 compaction | 4.875 | (4.4931*148 + 4.875)/149 = 669.8538/149 = **4.4957 / 149** | +0.0026 |
| Improving complex SQL performance on Trino with dbt | 4.6722 / 9 | Q4 dbt ephemeral/view | 3.5625 | (4.6722*9 + 3.5625)/10 = 45.6123/10 = **4.5612 / 10** | -0.1110 |

Federation row **4.49944 / 310 UNCHANGED** (NOT probed per iter472-498 directive).

---

## Next-teacher actions (HIGH PRIORITY for iter499)

1. **r17 (or wherever dbt materializations are canonicalized) — install LEADING CANONICAL block at top of `view` and `ephemeral` sections**:
   - DO-WRITE banner: "A `view` materialization creates a **database VIEW** = a stored SELECT definition. It stores NO row data, takes negligible storage (just the query text), and is RE-EXECUTED on every query."
   - DO-NOT-WRITE banner: ~~"view creates a persistent table that takes up storage"~~ — WRONG. Views store query logic, not rows.
   - DO-NOT-WRITE banner: ~~"views can be indexed in Trino"~~ — WRONG. Trino has NO user-creatable secondary indexes on ANY object. Performance optimization for Iceberg tables uses partition design + Parquet file stats + Puffin NDV (via `ANALYZE TABLE`) — never user indexes.
2. **r17 — ephemeral "problems at scale" canonical**: lead with **compile-time SQL bloat** as the load-bearing failure mode (N downstreams = N inlined copies → planner stress + Jinja compile time + no warehouse object to inspect/profile), NOT just "re-evaluated each query".
3. **r17 — decision table refresh**: `view` for cheap freshness-critical staging models (light transforms, fresh data, infrequently queried); `table` for expensive transforms queried often; `incremental` for large append-only fact loads; `ephemeral` only for very small reusable scalar/expression macros referenced ONCE.
4. **Reconcile-in-place** any other resource that mentions Trino "indexes" — replace with partition design + Puffin stats canonical pointer.

## Judge probe targets for iter499

- **HIGH**: dbt view materialization re-probe from a different keyword phrasing ("does my dbt view cost storage?" or "how do I speed up a dbt view in Trino — can I add an index?") — confirm the fab fixes route correctly.
- **HIGH**: Trino "index" probe from a different angle ("how do I create an index on my Iceberg table for fast filtering?") — confirm responder pivots to partition design + file pruning + Puffin NDV rather than fabricating an index DDL.
- **MEDIUM**: Q1 MERGE 3rd-angle re-probe — try "upsert/delete from a Kafka topic into Iceberg via Trino" keyword phrasing to stress the r13 → r27 §4.6B routing under different vocabulary.
- **MEDIUM**: EXECUTE optimize partition-predicate variant (`WHERE event_date >= DATE '2026-06-01'`) — confirm Trino-only targeted compaction is covered.
- **LOW**: ephemeral compile-time bloat probe ("my dbt model compile is slow — could ephemeral models be the cause?") — confirm new canonical lands.
- **DO NOT PROBE**: federation §13.x (per standing directive — federation row 4.49944/310 stays untouched).
