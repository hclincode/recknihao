# Iter669 Judge Feedback

**Iteration:** 669
**Phase:** extended
**Overall avg:** 4.375 / 5 → **PASS**

---

## Per-question scores

### Q1 — Iceberg row-level UPDATE (one customer's email across all rows)

**Answer:** `UPDATE iceberg.analytics.orders SET email = ... WHERE customer_id = 42;` + commentary ("CoW default", expire_snapshots releases old files, no special syntax).

| Dim | Score | Note |
|---|---|---|
| Accuracy | 3.5 | Core UPDATE SQL is exactly correct for Trino 467 / Iceberg v2 (verified at trino.io/docs/467/sql/update.html + connector/iceberg.html). **HOWEVER the "CoW default" claim is materially wrong.** Trino 467 Iceberg writes are **merge-on-read (MoR) by default** — UPDATE produces position delete files + new data files, not whole-file rewrites. CoW is a Spark-side option, not Trino's default. Verified via Starburst blog ("Trino write operations on Iceberg tables follow the merge-on-read design") and trino.io issue #17272 (CoW mode is an open feature request, not the default). |
| Completeness | 3.5 | Covers core UPDATE + snapshot lifecycle + expire_snapshots reclaim. Missing: any mention that the UPDATE will produce position-delete + new data files (relevant to maintenance/file count). |
| Clarity | 4 | Plain SQL + one-sentence narrative. Easy to follow. |
| Actionability | 4 | Engineer can copy/paste and run. The CoW misframing won't break the query but will confuse them when they inspect the resulting file layout. |
| **Q1 avg** | **3.75** | |

**FLAG:** "CoW default" is the kind of tangential-but-wrong storage-mode note that erodes trust. If an engineer reads this and then runs `SELECT * FROM "orders$files"` expecting whole-file rewrites, they will see position delete files instead and be confused.

---

### Q2 — Iceberg DELETE for GDPR (permanently remove all rows for one user_id)

**Answer:** `DELETE FROM iceberg.analytics.events WHERE user_id = '...';` + MoR position-delete explanation + `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')` + Spark `CALL iceberg.system.rewrite_position_delete_files(...)` + 7d min-retention + `iceberg.expire-snapshots.min-retention` config lever for faster GDPR erasure.

| Dim | Score | Note |
|---|---|---|
| Accuracy | 4.5 | Core DELETE SQL exact. MoR + position-delete framing correct (trino.io/docs/467/connector/iceberg.html: "Tables using v2 of the Iceberg specification support deletion of individual rows by writing position delete files"). `expire_snapshots` ALTER TABLE EXECUTE form correct. 7d min-retention default + `iceberg.expire-snapshots.min-retention` lever correct. `rewrite_position_delete_files` Spark-only claim **verified correct** — Trino roadmap issue #27371 lists adding this procedure as future work; it is not in Trino 467. Minor nuance: Trino's OPTIMIZE *does* have partial position-delete cleanup when whole partitions are selected via enforced predicates (per trino issue #24086), but the dedicated dense-pack procedure remains Spark-only. The responder's framing is essentially correct, just slightly less nuanced. |
| Completeness | 4.5 | Hits all four GDPR layers: logical delete, position-delete physical state, snapshot retention reclaim, compaction. Missing: optional note that for GDPR-grade erasure you also need to run `remove_orphan_files` after expire_snapshots. |
| Clarity | 4 | Three-stage mental model (logical delete → MoR markers → physical cleanup) is well-sequenced. Slight jargon density ("position-delete marker files", "min-retention") could trip a beginner. |
| Actionability | 4.5 | Engineer has both the immediate query and the cleanup path with concrete tunables. |
| **Q2 avg** | **4.375** | |

---

### Q3 — MERGE upsert (nightly batch insert + update on customer_id)

**Answer:** Canonical `MERGE INTO ... USING ... ON ... WHEN MATCHED THEN UPDATE SET ... WHEN NOT MATCHED THEN INSERT (...) VALUES (...)` with explicit column lists on both branches + `current_timestamp` + caveat that Trino 467 requires explicit columns (no INSERT * / UPDATE SET * Spark shorthand).

| Dim | Score | Note |
|---|---|---|
| Accuracy | 5 | Exact canonical Trino 467 MERGE syntax (verified trino.io/docs/467/sql/merge.html). Both branches use explicit column lists as required. `current_timestamp` is a valid Trino scalar. Atomic single-statement framing correct. Spark-shorthand-not-supported caveat correct (and saves the engineer from a parse error). |
| Completeness | 5 | All three required clauses, dedup-via-source contract is implicit, atomic semantics noted. Could optionally mention the "one source row per target key" requirement (MERGE fails if a target row matches multiple source rows) but this is a nice-to-have, not a gap. |
| Clarity | 4.5 | Standard MERGE template; column lists make the data flow self-documenting. |
| Actionability | 5 | Drop-in dbt-friendly statement. |
| **Q3 avg** | **4.875** | |

---

### Q4 — Month-over-month revenue growth %

**Answer:** CTE `monthly_revenue` with `DATE_TRUNC('month', order_date) + SUM(amount) GROUP BY`; outer SELECT uses `LAG(total_revenue, 1) OVER (ORDER BY month)` four times for prev/diff/divide; `CASE WHEN LAG IS NULL THEN NULL` for first-month guard; `NULLIF` for divide-by-zero guard; `* 1.0` for decimal coercion; date-spine caveat for gap months.

| Dim | Score | Note |
|---|---|---|
| Accuracy | 5 | All Trino 467 dialect-valid. LAG in SELECT/CASE (not WHERE) — valid. NULLIF divide-by-zero idiom correct. `* 1.0` decimal coercion correct (Trino integer division would truncate without it). Date-spine caveat for gap months accurate — LAG returns the previous *row*, not the previous *calendar month*, so a gap month produces a misleading "month-over-month" against an older month. |
| Completeness | 4.5 | Hits all five expected layers (monthly agg, LAG, first-row NULL guard, div-by-zero guard, decimal coercion) + the date-spine subtlety. |
| Clarity | 4 | Slightly verbose: 4x repetition of `LAG(total_revenue,1) OVER (ORDER BY month)` instead of one more CTE adding `prev_month_revenue` once. Valid but harder to read. |
| Actionability | 4.5 | Engineer can paste this into the BI tool and it works. The verbosity is a maintenance smell but not a defect. |
| **Q4 avg** | **4.5** | |

---

## Overall

| Q | Avg |
|---|---|
| Q1 UPDATE | 3.75 |
| Q2 DELETE/GDPR | 4.375 |
| Q3 MERGE | 4.875 |
| Q4 MoM growth | 4.5 |
| **Overall** | **4.375** |

**Verdict: PASS** (4.375 ≥ 3.5).

**Flagged weak answer:** Q1 — the "CoW default" claim is materially wrong for Trino 467 (Trino writes MoR by default; CoW is a Spark/upstream-Iceberg option not the Trino default). Core UPDATE SQL is correct, so the answer is still net-passing, but this is a recurring kind of error: tangential storage-mode notes drift from Trino-specific truth into generic-Iceberg lore.

---

## Teacher feedback (recommendation for iter670)

**Recommend iter670 = FIX-A: Clarify Trino-Iceberg default delete/update mode is MoR (not CoW).**

The Q1 CoW-default error is the only verified-false claim in this iteration and it is a recurring confusion vector (Iceberg-spec default vs Trino-write-mode default). Recommended targeted edit:

1. **r05 / r16 / r17 row-level DML sections** — surface near the canonical UPDATE / DELETE / MERGE examples the explicit statement: **"Trino 467's Iceberg connector writes in merge-on-read (MoR) mode by default. UPDATE / DELETE / MERGE on Iceberg v2 tables produce position delete files, not full-file rewrites. CoW mode is a Spark-side option and is tracked as a Trino roadmap item (trinodb/trino#17272); it is not the Trino default."**

2. **r16 (maintenance) cross-reference** — add a one-line cross-ref next to the `rewrite_position_delete_files` Spark-only note: **"Trino's `ALTER TABLE ... EXECUTE optimize` can compact position-delete files only when an enforced whole-partition predicate is supplied (trinodb/trino#24086); for general position-delete compaction, the dedicated procedure remains Spark-only (Trino roadmap #27371)."**

This is a single small, surgical clarification — no broad rewrite. All other answers (Q2, Q3, Q4) are clean and need no edits.

**Do NOT bump training/state.json** (already at 669 per teacher).

**Reconcile-don't-append discipline:** if any existing r-file currently says "Trino Iceberg defaults to CoW" or implies CoW-default, FIX-A must also remove/correct that line in the same pass.

---

## Sources verified

- [Trino 467 UPDATE](https://trino.io/docs/467/sql/update.html)
- [Trino 467 DELETE](https://trino.io/docs/467/sql/delete.html)
- [Trino 467 MERGE](https://trino.io/docs/467/sql/merge.html)
- [Trino 467 Iceberg connector](https://trino.io/docs/467/connector/iceberg.html)
- [Starburst: Apache Iceberg DML & Maintenance in Trino](https://www.starburst.io/blog/apache-iceberg-dml-update-delete-merge-maintenance-in-trino/) — confirms Trino writes MoR by default
- [trinodb/trino#17272 — Support copy-on-write mode for Iceberg write](https://github.com/trinodb/trino/issues/17272) — confirms CoW is not the Trino default
- [trinodb/trino#24086 — Delete files not removed after Iceberg maintenance ops](https://github.com/trinodb/trino/issues/24086) — confirms partial Trino OPTIMIZE position-delete cleanup
- [trinodb/trino#27371 — Iceberg roadmap incl. RewritePositionDeleteFiles for Trino](https://github.com/trinodb/trino/issues/27371) — confirms `rewrite_position_delete_files` is Spark-only at Trino 467
