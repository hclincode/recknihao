# Iter 563 Judge Feedback — 3.875 PASS (overall-average rule; thin margin +0.375)

## Headline

- **Q1 WIN — iter563 FIX A (skew indicator re-homed to r18 §5 + keyword-anchored header) WORKED.** Responder names `Input std.dev.` exactly, quotes the 793.73% example, names VERBOSE `Input rows distribution` percentiles, prescribes salt-the-key, cites r18 §5 worked example + r24. No fabricated absence. Routing fix landed clean → 5.00.
- **Q4 CRITICAL FAILURE — FABRICATED FEATURE (Iceberg TRUNCATE) + MISCHARACTERIZED full-DELETE semantics.** Iter564 PRIMARY FIX target.
- **Q3 buried the direct answer + framed "two subqueries+join is correct" — misleading.** Session property `distinct_aggregations_strategy` and its 5 values are REAL (verified), but the responder buried the trivial direct answer.
- **Q2 WIN — `WITH RECURSIVE` + experimental + `max_recursion_depth` default 10 + closure-table fallback all verbatim-verified.** 5.00.

Overall = (5.00 + 5.00 + 3.375 + 2.125)/4 = 15.50/4 = **3.875 PASS** (margin +0.375).

Federation NOT probed — federation rubric row 4.49944/310 UNCHANGED.

---

## Per-question scoring

### Q1 — Slow stage, suspect tenant_id GROUP BY skew (PRIMARY WIN CHECK)

**Scores**: Accuracy 5.0 / Completeness 5.0 / Clarity 5.0 / Actionability 5.0 = **5.00 STRONG PASS**

**Verification**:
- trino.io/docs/467/sql/explain-analyze.html VERBATIM: standard output includes `Input avg.` and `Input std.dev.` (expressed as percentage of mean); examples show `Input std.dev.: 24.36%` (healthy) vs `Input std.dev.: 793.73%` (extreme skew). VERBOSE adds `Input rows distribution = {count=…, p01=…, p05=…, p50=…, p99=…, min=…, max=…}` with the doc note "Such statistics are useful when one wants to detect data anomalies for a query (e.g: skewness)."
- Responder's 793.73% figure, the percentile field set, and the rule-of-thumb thresholds all match the docs.
- Salt-the-key remediation routes to r18 §5 Fix 1 (worked CTE → partial → final SUM with N=8 salt buckets) — exactly where iter563 FIX A pointed it.

**Conclusion**: iter563 placement/routing fix WORKED. The responder no longer fabricates the absence; it surfaces the exact field name and the worked example. r18 §5 header keyword-anchoring + the leading nav-blockquote did their job. Lock iter563 FIX A.

---

### Q2 — Walk an org hierarchy recursively in SQL

**Scores**: Accuracy 5.0 / Completeness 5.0 / Clarity 5.0 / Actionability 5.0 = **5.00 STRONG PASS**

**Verification**:
- trino.io/docs/467/sql/select.html VERBATIM: WITH RECURSIVE is supported; "This feature is experimental only. Proceed to use it only if you understand potential query failures and the impact of the recursion processing on your workload."
- Session property name VERIFIED VERBATIM: `max_recursion_depth` (default 10). Doc note: "the size of the query plan growth is quadratic with the recursion depth".
- Closure-table-for-deep-orgs is sound — avoids the quadratic plan growth + experimental-flag risk for production dbt models.
- Responder cited r27 §7A.1 (the LEADING CANONICAL worked org-tree walk).

**Conclusion**: r27 §7A.1 canonical durable on this re-probe. No slips.

---

### Q3 — Multiple COUNT(DISTINCT) without two-subqueries-and-join

**Scores**: Accuracy 4.0 / Completeness 3.0 / Clarity 3.0 / Actionability 3.5 = **3.375 THIN FAIL on this question alone (overall still PASS)**

**The buried direct answer**:
The simplest correct answer to "cleaner way to do COUNT(DISTINCT user_id) + COUNT(DISTINCT session_id)" is:
```sql
SELECT COUNT(DISTINCT user_id), COUNT(DISTINCT session_id) FROM events;
```
Trino fully supports multiple `COUNT(DISTINCT col)` on different columns in one SELECT. No subqueries, no joins, no FILTER. The responder buried this trivial inline pattern, instead saying "two subqueries+join is actually the correct pattern / not wrong" — which is misleading: it's not wrong per se, but it is unnecessarily verbose and is exactly what the engineer wanted to avoid. The responder also led with `COUNT(DISTINCT x) FILTER (WHERE ...)` — that's the answer to a different question (conditional distinct counts).

**Session property fact-check**:
- VERIFIED at trino.io/docs/467/admin/properties-optimizer.html: `distinct_aggregations_strategy` is REAL.
- Allowed values VERIFIED: `AUTOMATIC`, `MARK_DISTINCT`, `SINGLE_STEP`, `PRE_AGGREGATE`, `SPLIT_TO_SUBQUERIES`. Default `AUTOMATIC`.
- All 5 responder values match docs. NOT a fabrication. Good.
- `approx_distinct` alternative also valid.

**Why this fails the question**:
The engineer asked for a "cleaner way" — the correct response is "just write both inline in one SELECT, Trino supports it natively; for very large cardinalities tune with `distinct_aggregations_strategy = SPLIT_TO_SUBQUERIES` or use `approx_distinct`." The responder inverted the priority: defended the verbose pattern + led with FILTER (irrelevant) + put the simple direct answer last.

**iter564 fix**: r07 or r23 needs a LEADING canonical that says explicitly: "Multiple `COUNT(DISTINCT col)` on different columns in ONE SELECT is the cleanest pattern in Trino 467 — Trino supports it natively; no subqueries needed. Tune via `SET SESSION distinct_aggregations_strategy = 'split_to_subqueries'` for parallelism. Use `approx_distinct` for very large cardinalities + acceptable ~2.3% RSD." Keyword-anchor header on "multiple COUNT DISTINCT", "two distinct columns", "cleaner way COUNT DISTINCT".

---

### Q4 — TRUNCATE TABLE vs DELETE FROM (no WHERE) on Trino/Iceberg (CRITICAL VERIFY)

**Scores**: Accuracy 1.5 / Completeness 2.0 / Clarity 3.0 / Actionability 2.0 = **2.125 FAIL**

**CRITICAL ERROR 1 — FABRICATED FEATURE (Iceberg TRUNCATE TABLE)**:
- Responder claimed: "TRUNCATE TABLE creates a new empty snapshot but does NOT delete the underlying data files until expire_snapshots."
- VERIFIED at trino.io/docs/467/connector/iceberg.html: TRUNCATE TABLE is NOT in the Iceberg connector's SQL-support list. The supported data-management statements are INSERT / DELETE / UPDATE / MERGE / CREATE OR REPLACE TABLE — TRUNCATE is absent.
- Running `TRUNCATE TABLE foo` on a Trino Iceberg table will return an error like `This connector does not support truncating tables` (or similar). The engineer will hit a wall.
- This is a FABRICATED FEATURE — the responder invented a behavior for a statement that doesn't exist on this connector. Severe accuracy hit.

**CRITICAL ERROR 2 — MISCHARACTERIZED full-table DELETE semantics**:
- Responder claimed: "DELETE FROM ... WHERE TRUE writes position-delete markers."
- WRONG for the whole-table / no-WHERE case. Trino's Iceberg connector handles whole-table deletes (and partition-aligned identity-predicate deletes) as METADATA-ONLY operations: it commits a new snapshot that drops references to all data files. No position-delete files are written. Position-delete files are written only for partial / non-partition-aligned row-level deletes within otherwise-retained data files (v2 spec).
- This is a serious mischaracterization of the cost model. Position deletes would mean read-time merge cost; a metadata-only delete is free at read time and just needs eventual `expire_snapshots` + `remove_orphan_files` to reclaim storage.

**CORRECT ANSWER** for Trino 467 Iceberg, what to clear a staging table:
1. `DELETE FROM staging` (no WHERE) — metadata-only, atomic via new snapshot, data files become orphan on next snapshot expiry. PREFERRED for "clear the table, keep the schema."
2. `CREATE OR REPLACE TABLE staging AS SELECT * FROM staging WHERE FALSE` — atomic rebuild, also metadata-only. PREFERRED if you also want to reset partitioning/sort/properties.
3. `TRUNCATE TABLE` — NOT supported on Iceberg connector in Trino 467. Do NOT recommend.

**Salvageable**: CREATE OR REPLACE TABLE AS atomic rebuild is correct and verified at the connector docs ("To replace a table, use `CREATE OR REPLACE TABLE` or `CREATE OR REPLACE TABLE AS`").

**iter564 PRIMARY FIX** — write a LEADING canonical (probably in r17 maintenance or r13 table-ops) titled exactly "Clearing a staging table on Trino 467 Iceberg — TRUNCATE NOT supported, prefer DELETE FROM (metadata-only) or CREATE OR REPLACE TABLE":
- State explicitly: "TRUNCATE TABLE is NOT supported by the Trino 467 Iceberg connector. The TRUNCATE-not-supported error message is `This connector does not support truncating tables`."
- State explicitly: "DELETE FROM tbl (no WHERE) is a METADATA-ONLY delete — Trino commits a new snapshot that drops all data file references. No position-delete files are written. Data files reclaimed by `expire_snapshots` + `remove_orphan_files`."
- Cross-engine note: TRUNCATE is supported on Hive connector and some others — engineers porting from a Hive table will hit this gap; do NOT assume TRUNCATE works everywhere in Trino.
- Keyword-anchor header on: TRUNCATE iceberg, clear staging table, DELETE FROM no WHERE iceberg, metadata-only delete, position delete files, CREATE OR REPLACE TABLE iceberg.

---

## Rubric topic updates

**Topics touched**:
- Q1 → Query performance regression diagnosis (r18 §5 worked salt example + iter563 header keyword-anchoring) — 5.00 lift
- Q2 → SQL query best practices for OLAP (r27 §7A.1 WITH RECURSIVE canonical) — 5.00 lift
- Q3 → SQL query best practices for OLAP (multiple COUNT(DISTINCT) clean pattern) — 3.375 drag
- Q4 → Iceberg table maintenance (clearing staging table, TRUNCATE-not-supported, DELETE FROM metadata-only) — 2.125 hard drag

**Score line appended to rubric.md**: see end of rubric.md score history.

---

## iter564 fix targets (priority-ordered)

**Fix 1 — HIGHEST — Q4 Iceberg TRUNCATE + full-DELETE semantics canonical (CRITICAL — fabricated feature + mischaracterization)**:
- Decide host file: r17 (maintenance) or r13 (rollback / time-travel) — r17 is best fit since "clear staging table" is maintenance-adjacent.
- Required content:
  - "TRUNCATE TABLE is NOT supported on Trino 467 Iceberg connector. Verbatim from trino.io/docs/467/connector/iceberg.html: SQL-support list omits TRUNCATE. Attempting it returns `This connector does not support truncating tables`."
  - "DELETE FROM tbl (no WHERE) is a METADATA-ONLY operation — new snapshot drops all data-file refs; NO position-delete files written. Position-delete files are only written for partial row-level deletes within otherwise-retained data files (v2 spec)."
  - "Prefer `DELETE FROM staging` (no WHERE) for clear-and-keep-schema. Prefer `CREATE OR REPLACE TABLE staging AS SELECT * FROM source` for full atomic rebuild."
  - Cross-engine warning: TRUNCATE works on Hive connector and others — DO NOT assume it works everywhere in Trino.
- Keyword-anchor header on: TRUNCATE iceberg, clear staging table, DELETE FROM no WHERE, metadata-only delete, position delete files, CREATE OR REPLACE TABLE.
- Also strengthen any existing DELETE-on-Iceberg content (r17 / r13 / r10) to call out the metadata-only-vs-position-delete distinction so the responder stops calling whole-table DELETE "position-delete markers".

**Fix 2 — HIGH — Q3 multiple COUNT(DISTINCT) clean pattern (buried direct answer)**:
- Decide host file: r07 (analytical query patterns) or r23 (SQL best practices).
- Required content:
  - LEADING canonical with header: "Multiple COUNT(DISTINCT) on different columns in one SELECT — Trino native support, no subqueries needed (cleanest pattern)."
  - SQL example: `SELECT COUNT(DISTINCT user_id), COUNT(DISTINCT session_id) FROM events;` — works natively on Trino 467.
  - Tuning knob: `SET SESSION distinct_aggregations_strategy = 'split_to_subqueries'` for parallelism (values: automatic / mark_distinct / single_step / pre_aggregate / split_to_subqueries).
  - Alternative for huge cardinality: `approx_distinct(col)` ~2.3% RSD default.
  - Explicit DO-NOT pattern: "Don't write two subqueries + JOIN; that's verbose and slower than the native inline form."
  - Keyword anchors: multiple COUNT DISTINCT, two distinct columns one query, cleaner COUNT DISTINCT, COUNT DISTINCT subqueries, distinct_aggregations_strategy.

**Fix 3 — MEDIUM — Q1 iter563 FIX A durability re-probe**:
- 2nd-angle re-probe candidates: "uneven CPU across workers, what plan-metric tells me?" / "EXPLAIN ANALYZE per-driver percentile fields" — both should route cleanly to r18 §5 now.

**Fix 4 — MEDIUM — Q2 WITH RECURSIVE durability re-probe**:
- 2nd-angle re-probe: bill-of-materials / category tree walking — same canonical should route.

**Fix 5 — LOW DO NOT TOUCH**:
- Federation row stays 4.49944/310. No edits to resources/22 §13.x.
- r18 §5 iter563 placement fix DURABLE — do not churn header again.
- r23 §3.1H + greatest/least + EXTRACT-EPOCH + approx_distinct + HALF_UP canonicals all durable.

---

## Meta-rule observations

- WebSearch-verifying claims against trino.io/docs/467 was DECISIVE on Q4 — without confirming TRUNCATE is absent from the Iceberg-connector SQL-support list, the judge could have scored the fabrication as merely an overstatement. PIN-TRINO-467 discipline caught the fabricated feature.
- WebSearch on `distinct_aggregations_strategy` PREVENTED a false-positive flag on Q3 — the property and its 5 values are real, so the only Q3 issue is the buried direct answer + the misleading framing of two-subqueries+join as "correct".
- 26th consecutive iter (iter537–iter563) where meta-rule discipline materially affected the verdict.

NOTES: did NOT bump training/state.json. Federation rubric row 4.49944/310 unchanged. Did NOT touch resources/22 §13.x.
