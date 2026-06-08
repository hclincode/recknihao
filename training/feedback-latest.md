# Iter681 — Judge Feedback

**Iteration**: 681
**Phase**: extended
**Verdict**: PASS (overall avg 4.94 >= 3.5) — clean sweep; FIX-A CLOSED.

---

## CRITICAL VERDICT — iter680 CREATE-TABLE-no-PRIMARY-KEY FIX-A (Q1 re-probe)

**FIX-A STATUS: CLOSED.**

Iter680 Q1 (and its propagation through Q4 of iter680 DECIMAL-money) emitted `PRIMARY KEY (order_id)` inside a Trino `CREATE TABLE`, which parse-fails. The teacher's iter681 FIX-A:
- Replaced the load-bearing wrong row at r03:465 ("parse-and-ignore as metadata"),
- Propagated the grammar-layer truth to r03:446, r10:492, r23:3, r27:1681, r27:1726, r27:1735,
- Inserted a leading canonical SUPPORTED-vs-NOT-SUPPORTED block at r23:27 with worked money DDL,
- Verified all edits against trino.io/docs/467 via WebFetch.

Today the responder's Q1 DDL contains NO `PRIMARY KEY` clause. It uses `NOT NULL` only and correctly routes uniqueness to the ingestion/MERGE pipeline. The grammar-layer correction has landed. **FIX-A CLOSED — no regression.**

---

## Per-question scores

### Q1 — CREATE TABLE customers (Postgres-migrant wants PRIMARY KEY + NOT NULL) — FIX-A RE-PROBE
- **Accuracy**: 5 — DDL is parseable Trino 467 Iceberg CREATE TABLE. `NOT NULL` on `customer_id` + `email` is supported (verified at trino.io/docs/467/connector/iceberg.html: "The Iceberg connector supports setting NOT NULL constraints on the table columns"). `partitioning=ARRAY['day(created_at)']` valid (verified). `format='PARQUET'` valid (verified — also the default). No PRIMARY KEY in the DDL — matches the docs-verified grammar (trino.io/docs/467/sql/create-table.html shows only `[NOT NULL] [COMMENT comment] [WITH (...)]` as column constraints; no PRIMARY KEY token in the grammar). Responder's narrative correctly states Trino has no PRIMARY KEY constraint and routes uniqueness to the ingestion / MERGE pipeline.
- **Completeness**: 5 — covered (a) the DDL, (b) why PRIMARY KEY isn't there, (c) NOT NULL write-time enforcement, (d) uniqueness-via-pipeline workaround.
- **Clarity**: 5 — Postgres-mental-model bridge is explicit ("Trino does NOT support PRIMARY KEY"); the difference between "declared in DDL" vs "enforced in pipeline" is named.
- **Actionability**: 5 — copy-paste DDL; engineer knows the gap and the workaround surface.
- **Q1 verdict**: **5.00**
- **Minor note (NOT penalized)**: responder said "your Spark ingestion job must ensure uniqueness." Since the stack uses Spark for ingestion (prod_info.md), this is contextually accurate; the equally-valid dbt MERGE `unique_key` + dbt `unique` test path is one alternative — mentioning either is fine.

### Q2 — orders table with NOT NULL + per-column COMMENT
- **Accuracy**: 5 — `NOT NULL COMMENT 'text'` ordering on each column is the documented column-constraint clause order in the Trino 467 grammar synopsis (`column_name data_type [NOT NULL] [COMMENT comment] [WITH (...)]`). All five column declarations parse. `BIGINT NOT NULL COMMENT '...'`, `DECIMAL(12,2) NOT NULL COMMENT '...'`, `VARCHAR NOT NULL COMMENT '...'`, `TIMESTAMP(6) COMMENT '...'`, `VARCHAR COMMENT '...'` all valid. Table-property `partitioning=ARRAY['day(created_at)']` + `format='PARQUET'` valid. The claim that COMMENT lands in Iceberg metadata + appears in `SHOW CREATE TABLE` is correct.
- **Completeness**: 5 — required (`order_id`, `amount`) marked `NOT NULL`; optional (`created_at`, `status`) plain — covers the question's "required vs optional" split. Each column has its own COMMENT.
- **Clarity**: 5 — clause order shown by example, comment text is meaningful (not lorem-ipsum).
- **Actionability**: 5 — direct copy-paste.
- **Q2 verdict**: **5.00**
- **Minor stylistic note (NOT penalized)**: `amount DECIMAL(12,2) ... COMMENT 'Order total in cents'` is a labeling mismatch — `DECIMAL(12,2)` is dollars-with-2-decimals, not cents (cents-exact would be `DECIMAL(18,0)`). Doesn't affect Trino-dialect correctness; flag as a teacher copy-edit nit only.

### Q3 — surrogate key per row (no AUTO_INCREMENT/SERIAL)
- **Accuracy**: 5 — `uuid()` is a Trino 467 function returning the `uuid` type (verified at trino.io/docs/467/functions/uuid.html: "uuid() -> uuid ... a pseudo randomly generated UUID (type 4)"). `CAST(uuid() AS VARCHAR)` is a valid cast (UUID values cast to their canonical text form). Correctly states Trino has NO AUTO_INCREMENT / SERIAL / IDENTITY — confirmed by the iter681 FIX-A canonical at r23:27 and trino.io/docs/467/sql/create-table.html grammar (no GENERATED clause). The "generate at write/ingest time NOT at read time because uuid() re-executes per call" caveat is correct and important. The "don't partition/sort by random uuid — defeats file-skipping" caveat is the right Iceberg layout guidance (random keys produce uniform spread = zero pruning benefit).
- **Completeness**: 5 — gave the function, the cast, the no-AUTO_INCREMENT context, the per-call non-stability gotcha, and the partition/sort-key warning.
- **Clarity**: 5 — three pitfalls are each named.
- **Actionability**: 5 — copy-pasteable SELECT; clear write-once-at-ingest pattern.
- **Q3 verdict**: **5.00**

### Q4 — CTAS Parquet partitioned by month
- **Accuracy**: 5 — `CREATE TABLE ... WITH (partitioning=ARRAY['month(event_date)'], format='PARQUET') AS SELECT ...` is the documented Trino 467 CTAS form (verified at trino.io/docs/467/sql/create-table-as.html: WITH-clause supported on CTAS). `month()` transform valid for Iceberg (verified at trino.io/docs/467/connector/iceberg.html). The cautionary note "CTAS does NOT preserve NOT NULL — result columns are nullable; use explicit CREATE TABLE(... NOT NULL)+INSERT if you need NOT NULL" is the safe + practitioner-correct framing — Trino CTAS does not propagate column constraints from the SELECT source, and the docs do not document carry-over, so the cautious "if you need NOT NULL, use explicit CREATE + INSERT" guidance is appropriate.
- **Completeness**: 5 — gave the CTAS DDL with both table properties, the source predicate, the ORDER BY hint for write-time clustering, and the explicit-CREATE+INSERT escape hatch for NOT NULL.
- **Clarity**: 5 — clause order shown; CTAS-vs-explicit-DDL choice is framed in terms of which constraint guarantees the engineer wants.
- **Actionability**: 5 — copy-pasteable; the NOT NULL escape hatch is named.
- **Q4 verdict**: **5.00**

---

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 (CREATE TABLE no-PK FIX-A) | 5 | 5 | 5 | 5 | 5.00 |
| Q2 (NOT NULL + COMMENT) | 5 | 5 | 5 | 5 | 5.00 |
| Q3 (surrogate uuid()) | 5 | 5 | 5 | 5 | 5.00 |
| Q4 (CTAS partition+format) | 5 | 5 | 5 | 5 | 5.00 |
| **Overall** | | | | | **5.00** |

**Verdict**: **PASS** (5.00 >= 3.5). Clean sweep, all four answers parseable as Trino 467, no dialect leakage.

---

## Flagged weak answers

None. All four answers are clean Trino 467 DDL/SELECT.

---

## Teacher feedback (concise + actionable)

1. **iter681 FIX-A: CLOSED.** The CREATE-TABLE-no-PRIMARY-KEY inoculation across r03 / r10 / r23 / r27 worked end-to-end. The responder produced parseable DDL with no PRIMARY KEY token and correctly explained the absence + the pipeline workaround. The leading canonical at r23:27 is doing the load-bearing work the matrix row at r03:465 used to do incorrectly. Keep it in place; do NOT touch r03:465 / r23:27 / r27:1681-1735 for the foreseeable future.
2. **Minor copy-edit (NOT a regression)**: in r23 / r27 worked-DDL examples that show `amount DECIMAL(12,2) COMMENT 'cents'`, reconcile the label — `DECIMAL(12,2)` is dollars-and-cents (2 decimal places), not integer cents. If the canonical money example uses `DECIMAL(18,2)` (it does), make sure paired COMMENT text matches the scale. This is a doc clarity nit, not a dialect bug.
3. **Iter682 = DEFAULT NO-OP / durability-breadth.** All four answers are 5.00; FIX-A landed; no new regressions surfaced. Recommend next iteration probe DIFFERENT angles (federation re-probe, Iceberg maintenance edge cases, dbt incremental strategy choice) to maintain breadth coverage without re-poking already-bulletproofed CREATE TABLE constraint territory.
4. **No new resource edits required this cycle.** Resources are docs-verified correct on the CREATE TABLE constraint surface as of 2026-06-08.
