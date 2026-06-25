# Iter1111 Feedback — 4.66 STRONG PASS — NO RESOURCE DEFECT (Q2 partial gap is responder findability slip, not resource-sourced)

**Iter average: (4.9375 + 3.75 + 4.9375 + 5.000) / 4 = 4.65625 STRONG PASS** (margin +1.16 above 3.5).
**Recommendation: NO-OP.** All five contested Q1 claims source-verified CORRECT against Trino 467 docs. Q2 incremental-without-merge gap exists in the responder's answer BUT the canonical fix (merge strategy + unique_key for dedup correctness) is already documented in r28 at L150, L177, L1521, L1596, and §6.8 — this is Haiku grabbing the perf-side incremental advice without the correctness-side merge advice that lives in the same file. Per `feedback_synthesis_ceiling_stop_churning`, scope as per-instance one-off; do NOT churn additive content.

---

## Source verification (the five critical Q1 claims)

Verified vs trino.io/docs/current/sql/select.html via WebFetch + WebSearch:

| Responder claim | Verified? | Source |
|---|---|---|
| "Trino docs explicitly mark WITH RECURSIVE as EXPERIMENTAL" | **YES** | trino.io/docs/current/sql/select.html — *"This feature is experimental only. Proceed to use it only if you understand potential query failures and the impact of the recursion processing on your workload."* |
| "recursion depth cap defaults to 10" | **YES** | trino.io/docs/current/sql/select.html — *"recursion depth is fixed, defaults to 10, and doesn't depend on the actual query results"* |
| "SET SESSION max_recursion_depth = 50 to raise" | **YES** | session property name and form verified |
| "exceeding raises NOT_SUPPORTED: Recursion depth limit exceeded (does NOT silently truncate)" | **YES** | AWS Athena re:Post (same engine) shows exact message `NOT_SUPPORTED: Recursion depth limit exceeded (10). Use 'max_recursion_depth'`; r27 §7A.1 L3994 explicitly defangs the "silently truncates" misconception |
| "plan grows QUADRATICALLY with depth — doubling depth roughly quadruples plan size" | **YES** | trino.io/docs/current/sql/select.html — *"When changing the value consider that the size of the query plan growth is quadratic with the recursion depth."* |

All five contested claims about Trino's WITH RECURSIVE behavior are source-verified CORRECT. The judge prompt suggested doubt about (5) "quadratic vs linear" — Trino docs explicitly say **quadratic**, and the responder is correct.

---

## Per-question scoring

### Q1 — Oracle CONNECT BY PRIOR → Trino WITH RECURSIVE — 4.9375 (5.00 + 5.00 + 4.75 + 5.00) / 4

**Strengths**: All five contested claims verified against trino.io. Hits r27 §7A.1 canonical (L3954+) cleanly — experimental flag named, default=10 named correctly (not the wrong "100" / "1000" priors defanged at L3994), NOT_SUPPORTED error correctly named (not the "silently truncates" defanged misconception), quadratic-plan caveat correctly named. Closure-table fallback for very deep hierarchies is the dbt-recommended pattern at L3997+. Memory pin re-confirmed: r27 §7A.1 still authoritative and findable.

**Shave**: Recursive-CTE syntax assumes some SQL familiarity (base case + UNION ALL + recursive step pattern); a one-line "base = root rows, recursive = step that joins back to the partial result, UNION ALL stitches them" could lower the floor. Minor; -0.25 on Clarity only.

**Topic**: Oracle PL/SQL → dbt + Trino migration.
**Resource source**: r27 §7A.1 L3954–4024 (full canonical with caveats).

### Q2 — dbt ROW_NUMBER dedup model 45+ min — 3.75 (3.75 + 3.50 + 4.25 + 3.50) / 4

**Strengths**: Correctly identifies the window function is NOT the slowdown cause; correctly recommends `materialized='incremental'` + partition pruning by `day(occurred_at)` + `is_incremental()` lookback filter against `(SELECT MAX(occurred_at) FROM {{this}})`. Correctly self-corrects on QUALIFY (Trino 467 has no QUALIFY per memory pin `reference_trino_no_qualify`) and provides the subquery `WHERE rn = 1` form. Perf-side advice is sound.

**Real gap — structural correctness for a DEDUP semantic**:
- The example as written omits `incremental_strategy` (defaults to `append` in dbt-trino per docs.getdbt.com/reference/resource-configs/trino-configs) and omits `unique_key`.
- For a model whose purpose is "one row per user_id (latest)", a plain `append`-strategy incremental with a lookback re-processes the overlap window AND APPENDS those rows — producing **duplicate rows for already-seen user_ids on every run**. The dedup semantic breaks.
- The correct dedup-incremental form requires `incremental_strategy='merge'` + `unique_key='user_id'` (so MERGE INTO matches on user_id and updates in place), OR `incremental_strategy='delete+insert'` + `unique_key` for partition-replace patterns, OR `materialized='table'` for a full refresh.
- This is documented IN THE SAME RESOURCE the responder pulled the perf advice from: **r28 L177** explicitly: *"`incremental_strategy='append'` paired with a lookback window → `append` will INSERT duplicate rows for already-seen events in the lookback window. `merge` matches on `unique_key` and updates in place, preserving idempotence."* Also r28 L150 (cross-ref to r27 §6.8 worked example), r28 L1510–1547 (canonical late-arriving-data LOOKBACK variant pair with merge+unique_key), r28 L1596 (defanged "append+lookback = duplicates" anti-pattern).

**Verdict on the gap**: NOT a resource defect — the canonical correct form is documented at 5 distinct locations in r28. This is a **responder findability slip**: Haiku grabbed the perf-side incremental advice (incremental + partition + lookback) from r28 but did not also pull the correctness-side advice (merge + unique_key) that lives in the same file's anti-pattern table. Pattern matches `feedback_responder_broken_secondary_alternative` family — primary perf diagnosis correct, but the worked example would compile to a model that breaks dedup correctness over time.

**QUALIFY-then-retract presentation**: this is the responder correctly hitting memory pin `reference_trino_no_qualify` and self-correcting. Slightly awkward UX (engineer might wonder why QUALIFY was offered then withdrawn) but truthful and follows the canonical rewrite to subquery `WHERE rn = 1`. Per-instance Haiku phrasing artifact; NOT a resource-fixable defect.

**Topic**: Improving complex SQL performance on Trino with dbt.
**Resource source for the gap**: r28 L177, L1510–1547, L1596.

### Q3 — SELECT * defeats Iceberg columnar advantage — 4.9375 (5.00 + 4.75 + 5.00 + 5.00) / 4

**Strengths**: Correctly diagnoses that SELECT * reads all 60 column chunks from each Parquet file → ~12× more I/O than projecting 5 needed columns (5/60 ≈ 8% I/O reduction is concrete and correct). Correctly explains Parquet's columnar physical layout: all columns stored in one file but organized as separate column chunks within row groups, with the Trino reader seeking to each needed column chunk's byte range via the Parquet footer index. Decompression cost is per-column. The "list only the columns you need" actionable directive is exactly what an engineer needs to take away.

**Shave**: Did not explicitly mention complex-type/nested-column projection (Iceberg + Parquet support sub-field projection on structs), or how dictionary encoding amplifies the savings; both are nice-to-have but not load-bearing. -0.25 on Completeness only.

**Topic**: Column-oriented storage.

### Q4 — Monthly invoice SUM precision (12345.999999998 vs 12346.00) — 5.000 (5.00 + 5.00 + 5.00 + 5.00) / 4

**Strengths**: Correct root-cause diagnosis (IEEE-754 binary floating-point cannot exactly represent decimal cents like 0.10 — accumulated tiny round-off errors over many additions produce the …999998 tail). Correct fix at the type level: store money as `DECIMAL(18,2)` (Oracle `NUMBER` → Trino `DECIMAL` is the standard migration mapping per r27 type-rewrite section). Correct query-side guard: `CAST(SUM(amount) AS DECIMAL(18,2))` if amount is already DOUBLE/REAL and changing the column type is infeasible short-term. Correct guidance on when DOUBLE is appropriate (scientific / approximate measurements, never money). All four dimensions cleanly addressed.

**Topic**: SQL query best practices for OLAP (type-safe predicates + correct decimal/numeric handling).

---

## Score table

| Q | Topic | Acc | Compl | Clar | Act | Avg |
|---|---|---|---|---|---|---|
| Q1 | Oracle PL/SQL → dbt+Trino | 5.00 | 5.00 | 4.75 | 5.00 | **4.9375** |
| Q2 | Complex SQL perf on Trino+dbt | 3.75 | 3.50 | 4.25 | 3.50 | **3.7500** |
| Q3 | Column-oriented storage | 5.00 | 4.75 | 5.00 | 5.00 | **4.9375** |
| Q4 | SQL best-practices OLAP | 5.00 | 5.00 | 5.00 | 5.00 | **5.0000** |
| **Iter avg** | | | | | | **4.6563** |

**Margin: +1.16 above 3.5 pass threshold. STRONG PASS.**

---

## Source-verified defect classification

| Defect | Type | Resource-sourced? | Action |
|---|---|---|---|
| Q2 incremental example omits `incremental_strategy='merge'` + `unique_key` for dedup correctness | Responder findability slip | **NO** — canonical merge+unique_key form documented in r28 at 5 locations (L150, L177, L1510–1547, L1596, §6.8 cross-ref to r27) | **NO-OP**; per `feedback_synthesis_ceiling_stop_churning` |
| Q2 QUALIFY-then-retract presentation | Responder per-instance phrasing artifact | NO — memory pin `reference_trino_no_qualify` correctly hit; subquery WHERE rn=1 rewrite is canonical | **NO-OP**; truthful self-correction |

No fabrications. No imported-prior self-errors. No `::` cast / false-semi-join / regex-backslash / INTERVAL-quarter-week / OFFSET-before-LIMIT / CAST-truncate / EXECUTE-rollback-on-467 / Spark-Oracle-spillover. No defang regressions.

---

## Teacher guidance

**Primary recommendation: NO-OP this iter.**

- **r27 §7A.1 CONNECT BY → WITH RECURSIVE canonical**: REACHED CLEANLY on Q1 — all five technical claims hit correctly (experimental, default=10, NOT_SUPPORTED on exceed, quadratic plan growth, dbt closure-table fallback). The §7A.1 anti-defang block at L3994 ("DO NOT WRITE default 1000 / default 100 / silently truncates") successfully blocked the four most common misconceptions. Memory pin durable.

- **r28 dedup-incremental canonicals**: PRIMARY perf advice REACHED on Q2 (incremental + partition + lookback), but the SAME-FILE correctness advice (merge + unique_key) was NOT pulled into the worked example. This is the responder grabbing one of two co-located canonical pieces. Resources are already comprehensive; no additive content can durably force Haiku to always pair them. Per `feedback_synthesis_ceiling_stop_churning`, accept the occasional per-instance slip and re-probe in 2–3 iterations to confirm it's an artifact, not a recurring pattern.

- **r03 columnar canonical**: REACHED CLEANLY on Q3 — Parquet column-chunk physical layout, byte-range seek, per-column decompression all named correctly with concrete 5/60 = 8% I/O example.

- **r23/r27 DECIMAL-vs-DOUBLE money canonical**: REACHED CLEANLY on Q4 — root cause (IEEE-754 binary float), type fix (DECIMAL(18,2)), query fix (CAST), Oracle NUMBER → Trino DECIMAL migration mapping all named correctly.

**Optional next-sweep durability probes (no resource edits, just probe)**:
- Q2-shape re-probe with a different domain (e.g., latest-per-session_id or latest-per-account_id dedup): if the merge+unique_key omission RECURS, consider a `feedback_defang_donotwrite_snippets`-style inline `-- WRONG: missing incremental_strategy='merge'` defang on the existing r28 canonical OR hoisting the "incremental dedup requires merge+unique_key" guarantee into a top-of-file STEP-0 router in r28.
- Storage-tiering 7th datapoint (3.5625/6 — thinnest passing row).
- dbt-model-contracts 7th angle (4.391/6).
- cost-considerations 21st angle (4.2129/20).

**No federation re-probe** (4.50244/312 fragile-PASS preserved). **No CBO re-probe** unless a bulletproofed angle is available (4.5716/20, +0.072 margin to raised 4.5 threshold preserved per iter1108).

---

## Iter1111 summary

Four varied less-recently-probed angles touched four distinct required topics. Three pristine (~5.0) on canonical traps (recursive CTE Oracle migration, columnar SELECT * pushdown, DECIMAL-vs-DOUBLE money); one shave (3.75) on a dedup-incremental correctness gap that is sourced but unconsumed in the resources. NO new defects. NO resource edits. **NO-OP** recommended.

Pattern observation: the WITH RECURSIVE Q1 hit ALL five contested technical claims correctly including the quadratic-plan-growth claim that the judge prompt suggested might be a linear-unroll fabrication. The Trino source-of-truth (trino.io/docs/current/sql/select.html) confirms "size of the query plan growth is quadratic with the recursion depth" verbatim — responder is right, the suspicion was unfounded. Continue verify-first-against-trino.io before suspecting a responder fabrication on a verifiable technical claim; the responder's recursive CTE understanding here is durable resource-channeled correctness.
