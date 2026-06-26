# Iter 1128 — Judge Feedback

**Iter average: 4.8906 STRONG PASS (margin +1.3906).** All four answers clean and source-verified against RAW Trino 467 docs (window.html, math.html, iceberg.html connector). No defects, no new watch streams, no recurring family signatures. Q1/Q2 land 5.00 (RANGE+INTERVAL window frame and width_bucket(bins) array overload both verified correct in 467). Q3 minor completeness shave (-0.3125) for Spark-only re-partition path (Trino EXECUTE optimize alternative not mentioned for re-partitioning OLD data — defensible in this prod stack since Spark is already the ingestion engine, but a Trino-native option is the more natural reach for the queries team). Q4 minor completeness shave (-0.125) for not explicitly flagging the engineer's self-contradictory premise ("NULL rows appearing yet `!= ''` would have already EXCLUDED them — possibly whitespace strings or filter not applied where you think"); the SQL semantics + robust filter recommendations are fully correct. **RECOMMENDATION = NO-OP** (commit rubric+feedback only; do not edit resources/ this iter).

---

## Per-question scoring

### Q1 — 7-day rolling average of daily signups; cleaner than 7-way self-join; how to look back exactly last 7 days — **5.0000**

| Dim | Score | Reasoning |
|---|---|---|
| Acc | 5.0 | `RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW` is valid Trino 467 (RANGE+INTERVAL window frame added in version 346, verified via trino.io/blog/2021/03/10/introducing-new-window-features.html — "the offset `interval '1' month` applies to `orderdate`, which is the sorting column"; offset must be compatible with sorting column type, DATE+DAY-interval valid). `AVG(COUNT(*)) OVER (...)` over a GROUP BY signup_date is legal SQL standard semantics (window evaluated AFTER aggregation phase; the aggregate's per-group result feeds the window function). Calendar-day claim accurate: RANGE is value-based, so a missing day with no row means the frame averages over fewer present rows (gap-correct — never includes a phantom zero for the missing day) — this is the correct behavior the responder describes. |
| Clar | 5.0 | Clear ROWS-vs-RANGE distinction, calendar-day framing motivates why the engineer wants RANGE not ROWS. |
| App | 5.0 | Exact SQL ready to paste; explains why this beats a 7-way self-join. |
| Compl | 5.0 | Fully addresses both the cleaner-than-7-way-self-join ask and the exactly-last-7-days ask. |

### Q2 — histogram of customers by monthly_api_calls into 0-99/100-499/500-999/1000+; built-in bucketing or CASE WHEN — **5.0000**

| Dim | Score | Reasoning |
|---|---|---|
| Acc | 5.0 | `width_bucket(operand, bins_array)` 0-based per spec — verified against trino.io/docs/current/functions/math.html: returns 0 if x is below the first lower bound, returns cardinality(bins) if x is at or above the last bound. ARRAY[100,500,1000] → bucket 0 for x<100, 1 for 100≤x<500, 2 for 500≤x<1000, 3 for x≥1000. Mapping the responder gave is exactly correct. Bins ARRAY must be sorted ascending DOUBLE (responder used `100.0,500.0,1000.0` literals — correct double typing avoids type-mismatch). |
| Clar | 5.0 | Explicit bucket-to-label table for non-OLAP engineer. |
| App | 5.0 | CTE + CASE label wrapper is the canonical pattern; engineer can paste directly. |
| Compl | 5.0 | Addresses built-in-vs-CASE choice cleanly. |

### Q3 — events partitioned by day; add customer_id partition so per-customer queries prune; drop+recreate or in-place — **4.6250**

| Dim | Score | Reasoning |
|---|---|---|
| Acc | 5.0 | `ALTER TABLE events SET PROPERTIES partitioning = ARRAY['day(occurred_at)', 'bucket(customer_id, 64)']` is correct Trino 467 Iceberg partition evolution syntax (verified via trino.io/docs/current/connector/iceberg.html — partition evolution is metadata-only / atomic metadata swap; old data retains old partition spec, new writes use new spec; queries remain correct because Iceberg's manifests carry per-file partition spec ID). `bucket(customer_id, 64)` correctly chosen over `identity(customer_id)` for high-cardinality customer_id (identity would create one partition per customer — partition explosion / manifest planning catastrophe per the established r10 §1389 partition-explosion canonical). Spark `CALL iceberg.system.rewrite_data_files(...rewrite-all=true...)` correctly attributed to Spark (NOT Trino — Trino has no `rewrite_data_files` procedure; Trino's equivalent is `ALTER TABLE ... EXECUTE optimize`). The `'run in spark-submit, NOT Trino UI'` parenthetical is a true statement. |
| Clar | 5.0 | Two-step structure (in-place metadata change + optional old-data rewrite) maps cleanly to the engineer's drop-vs-in-place framing. |
| App | 4.0 | Engineer is on a Trino-primary stack (per prod_info.md: Trino+Iceberg with Hive Metastore is the query engine; Spark is for ingestion). Responder gave ONLY the Spark re-partition path. Trino-native `ALTER TABLE events EXECUTE optimize` (no args) would also work and is the more natural reach for a queries-team workflow — it will rewrite files according to the CURRENT (new) partition spec. Spark CALL `rewrite_data_files` with `rewrite-all=true` is more thorough (forces full rewrite even of already-balanced files) and is a legitimate path given Spark already exists in this stack, but mentioning the Trino-side option would have been ideal. Per-instance shave only. |
| Compl | 3.5 | Missing Trino EXECUTE optimize alternative for re-partitioning old data; otherwise covers in-place metadata-only nature, old-data behavior, and new-spec semantics correctly. |

### Q4 — `WHERE company_name != ''` but NULL rows still appear; engineer assumed NULL and '' are the same — **4.8750**

| Dim | Score | Reasoning |
|---|---|---|
| Acc | 5.0 | Three-valued logic explanation correct: NULL ≠ '' evaluates to UNKNOWN (not TRUE, not FALSE), and a WHERE clause keeps rows only when the predicate is TRUE — so NULL rows ARE EXCLUDED by `!= ''`. All three filter forms (`IS NOT NULL AND != ''`, `length(...) > 0`, `COALESCE(...,'') != ''`) are correct and Trino 467-valid. Statement "only IS NULL/IS NOT NULL return TRUE/FALSE against NULL" correct per ANSI three-valued logic. |
| Clar | 5.0 | Cleanly walks the three-valued logic table (TRUE/FALSE/UNKNOWN cases) — accessible to a non-OLAP engineer. |
| App | 5.0 | Three robust filter forms; engineer can pick whichever matches their style. |
| Compl | 4.5 | The engineer's PREMISE was self-contradictory: they claimed NULL rows ARE appearing in their output BUT `!= ''` would have already EXCLUDED them. The semantic explanation is correct (NULLs are excluded by `!= ''`), but the responder didn't flag that the premise is impossible — the engineer's "NULL" rows may actually be whitespace strings (`' '`, `'\t'`) that print as blanks but are NOT NULL, OR the filter isn't running where they think. Naming this contradiction would have helped the engineer find the real bug. Per-instance shave only, NOT a resource gap. |

---

## Score table

| Q | Acc | Clar | App | Compl | Avg |
|---|---|---|---|---|---|
| Q1 (rolling avg + RANGE INTERVAL window frame) | 5.0 | 5.0 | 5.0 | 5.0 | **5.0000** |
| Q2 (width_bucket histogram) | 5.0 | 5.0 | 5.0 | 5.0 | **5.0000** |
| Q3 (Iceberg partition evolution in-place) | 5.0 | 5.0 | 4.0 | 3.5 | **4.6250** |
| Q4 (NULL vs '' three-valued logic) | 5.0 | 5.0 | 5.0 | 4.5 | **4.8750** |
| **Iter average** | | | | | **4.8906** |

**Overall: PASS (margin +1.3906 over 3.5 threshold)**

---

## Source-verified defects

**NONE.** All four answers verified clean against:
- trino.io/blog/2021/03/10/introducing-new-window-features.html (RANGE+INTERVAL window frame since 346, DATE+DAY interval supported)
- trino.io/docs/current/functions/window.html (window over aggregate semantics)
- trino.io/docs/current/functions/math.html + Trino 367 docs (`width_bucket(x, bins_array)` 0-based: returns 0 below first bound, cardinality(bins) above last)
- trino.io/docs/current/connector/iceberg.html (ALTER TABLE SET PROPERTIES partitioning = ARRAY[...] is in-place metadata-only; existing data retains old spec; queries remain correct via per-file partition spec ID in manifests)
- Spark Iceberg procedure docs (`CALL system.rewrite_data_files` is Spark-side, not Trino)

Q3's Spark-only re-partition path and Q4's premise-contradiction omission are PER-INSTANCE COMPLETENESS SHAVES, NOT resource-sourced defects. No FIX-A warranted. No new watch stream opened.

---

## Teacher guidance

**NO-OP.** Do not edit resources/ this iter. All four answers are correct on substance; the two minor shaves are per-instance completeness (Spark-only vs Trino-also, and not flagging a self-contradictory premise) — not patterns that recur across iters and not resource-sourced.

**Re-probe queue (carry-forward from iter1127, unchanged ordering):**
1. storage-tiering 9th angle (still thinnest required-topic row at 3.9219/8, +0.4219 margin)
2. dbt-snapshots SCD2 17th angle (check_cols edge cases, hard_deletes='new_record' downstream interaction)
3. cost-considerations 22nd angle (`$manifests` partition-cost attribution, per-tenant cost split)
4. query-perf-regression-diagnosis 21st angle (concurrent ETL-vs-dashboard contention oncall)
5. NEW: Trino-side EXECUTE optimize after partition evolution (re-probe Q3 from a Trino-only angle: "I changed partition spec from Trino — how do I re-partition old data from Trino, not Spark?") — would test whether responder reaches the Trino-native compaction path on a direct keyword route; if responder defaults to Spark CALL even when explicitly asked "from Trino," that's a findability boundary worth a one-line cross-ref in r17/r10. First-instance scope only — do NOT preempt.

**Watch streams: ALL CLOSED.** No active recurrences. No new watch streams opened this iter.

**Pattern observation:** 11-iter sustainment band shape: STRONG PASS iters 1090/1092/1093/1117/1118/1119/1121/1122/1125/1127/**1128** with LIGHT FIX-A iters 1091/1116/1124 reaching cleanly between and NO-OP+WATCH iters 1120/1123/1126 with all watches CLOSED on first re-probe. iter1128 4.8906 STRONG PASS reaffirms (a) RANGE+INTERVAL window frame is a durable competence (not a synthesis ceiling area), (b) `width_bucket(bins_array)` 0-based array overload is correctly understood (no Postgres-1-based imported-prior trap), (c) Iceberg partition evolution metadata-only semantics + identity-vs-bucket trade-off durable (extends iter1125's bucket fix lineage). Q3's Spark-only re-partition aside matches `feedback_responder_broken_secondary_alternative` shape (primary in-place answer perfect, secondary maintenance aside slightly narrow) — per-instance per the established discipline, no FIX-A. Q4's not-flagging-premise-contradiction is consistent with the responder's general "answer the literal question, don't editorialize on premises" style — not a defect. No content-lineage erosion; no recurring defect class.
