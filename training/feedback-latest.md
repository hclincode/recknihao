# Judge Feedback — Iteration 1290

**Overall**: 4 questions, average **4.625 STRONG PASS** (Q1 4.8125 PASS / Q2 4.8125 PASS / Q3 4.0 PASS / Q4 4.875 PASS). Massive recovery from iter1289 3.547 BARELY PASS (Q3 FAIL → Q1 FIX-A REACH-TEST clean PASS); all four answers route cleanly. iter1289-Q3 HARD WATCH `dbt ephemeral-basics findability` **CLOSES on 1st re-probe**.

**Headline**:
- **Q1 (ephemeral RE-PROBE) — FIX-A REACHED + iter1289-Q3 watch CLOSES.** Responder fully answers ("ephemeral creates NOTHING, not a temp table not a view; SQL inlined as a CTE at dbt COMPILE time; multi-downstream inlining bloat; promote to view/table at 3+ downstreams") matching the new r27 §3 QUICK-ANSWER canonical + r28 §3.3/§3.3A. Verified vs [docs.getdbt.com/docs/build/materializations](https://docs.getdbt.com/docs/build/materializations): "ephemeral models are not directly built into the database... dbt will interpolate the code from an ephemeral model into its dependent models using a common table expression (CTE)" + recommended use "only used in one or two downstream models" + "Overuse of ephemeral materialization can also make queries harder to debug." All facts match.
- **Q2 (string_agg → Trino) — SOLID PASS.** Responder gives canonical `listagg(sku, ', ') WITHIN GROUP (ORDER BY sku)` + `GROUP BY customer_id` + 90-day `WHERE` filter; correctly defangs listagg-as-window-function (does not exist) with `array_join(array_agg(...) OVER (...), ', ')` windowed alternative. Pin `reference_trino_listagg_native` confirmed at [trino.io aggregate.html](https://trino.io/docs/current/functions/aggregate.html) + [trinodb/trino #16982](https://github.com/trinodb/trino/issues/16982) "LISTAGG currently can't be used as a window function".
- **Q3 (write.distribution-mode small files) — PASS with completeness gap.** Hash-is-default claim resource-faithful AND verified at [apache/iceberg PR #6828](https://github.com/apache/iceberg/pull/6828) "Spark 3.3: Change default distribution modes" + Iceberg 1.2.0 sets `write.distribution-mode='hash'` for partitioned tables. The distribution-mode mechanism explanation (hash hash-shuffle / none fanout writer / range range-partition) is accurate, and `write.target-file-size-bytes=128MB` is correct. **BUT — completeness gap confirmed**: if hash is the default and engineer is on Iceberg 1.5.2, the "hundreds of tiny files after dbt loads" is much more likely caused by FREQUENT SMALL COMMITS (each dbt incremental run commits at least one data file per partition touched; many small batches accumulate small files regardless of distribution-mode), which distribution-mode does NOT fix. The real fix for already-accumulated small files is COMPACTION (`ALTER TABLE ... EXECUTE optimize` Trino-native, or Spark `rewrite_data_files`). Responder under-emphasizes compaction (only target-file-size-bytes mentioned, no `EXECUTE optimize` / `rewrite_data_files` lead). Distribution-mode explanation is correct + resource-faithful but the diagnostic answer for "tiny files after dbt runs" misses the dominant root cause.
- **Q4 (Oracle || NULL → Trino) — CLEAN SOLID PASS.** Trino || NULL-propagation correct (SQL-standard; both `||` and `concat` propagate NULL per [trino 467 string.md](https://github.com/trinodb/trino/blob/467/docs/src/main/sphinx/functions/string.md) — "same functionality as the SQL-standard concatenation operator"). Oracle's NULL-as-empty-string idiosyncrasy correctly framed as the divergence. `COALESCE(col, '')` workaround correct. `concat_ws(sep, ...)` "automatically skips NULL" verified at [trino.io string.html](https://trino.io/docs/current/functions/string.html) — "Any null values provided in the arguments after the separator are skipped."

| Q | Topic | Score | Status | Verdict |
|---|---|---|---|---|
| Q1 ephemeral RE-PROBE | Improving complex SQL perf on Trino with dbt | **4.8125** | PASS | All 3 sub-questions cleanly answered (no DB object, CTE-at-compile-time, multi-downstream bloat); iter1289 FIX-A REACHED |
| Q2 string_agg → Trino | SQL query best practices for OLAP | **4.8125** | PASS | Canonical listagg + 90-day filter + windowed alternative; pin `reference_trino_listagg_native` verified |
| Q3 write.distribution-mode | Iceberg partition design for SaaS: small-files / compaction | **4.0** | PASS | Hash-default + modes + target-file-size all correct; **completeness gap**: misses frequent-small-commit + compaction angle |
| Q4 Oracle \|\| NULL → Trino | Oracle PL/SQL → dbt+Trino migration | **4.875** | PASS | NULL-propagation + COALESCE fix + concat_ws skip-NULL alternative all verified |

---

## Q1 — Ephemeral RE-PROBE (4.8125 PASS — iter1289-Q3 WATCH CLOSES)

**Acc 4.75 / Clar 4.75 / Prac 5.0 / Compl 4.75.**

Responder routed cleanly to the new r27 §3 QUICK-ANSWER canonical + r28 §3.3/§3.3A. Every sub-question hit:

1. **"What does ephemeral physically create?"** → "NOTHING — not a temp table, not a view; SQL inlined as a WITH/CTE into every downstream at dbt COMPILE time; zero storage." Matches [docs.getdbt.com/docs/build/materializations](https://docs.getdbt.com/docs/build/materializations) verbatim: "ephemeral models are not directly built into the database. Instead, dbt will interpolate the code from an ephemeral model into its dependent models using a common table expression (CTE)."

2. **"Gotcha if reused from several places?"** → "Multiple downstreams → SQL duplicated/inlined into each → compile + Trino planning bloat (5 downstreams × 100-line ephemeral = 500 lines)." Matches r28 §3.3A's 5-step worked example pattern. Aligns with dbt's recommendation to use "only in one or two downstream models" + "Overuse of ephemeral materialization can also make queries harder to debug."

3. **"Ephemeral vs view?"** → Implicit: view is a queryable DB object with persistent SQL; ephemeral has no DB object. Responder also adds the actionable rule of thumb: "Promote to view/table if 3+ downstreams or >50 lines. For your small 1-downstream cleanup steps ephemeral is perfect."

iter1289 hedged "resources don't cover dbt materializations" on a near-identical question; iter1290 with the FIX-A applied (QUICK-ANSWER canonical at top of r27 §3 with anchors + cross-ref to r28 §3.3) routes confidently and exhaustively. Pattern matches the iter1271→1272 bloom-CREATE-467 r17-reconcile FIX-A close (1st re-probe clean) and the iter1233 custom-generic-test FIX-A close.

**Action**: **CLOSE HARD WATCH `iter1289-Q3 dbt ephemeral-basics findability reach-test`.** No further fix. Single-instance clean reach — re-probe under varied ephemeral framings 1-2 more iters before promoting to fully resolved, but the routing path is now established.

Minor shave (-0.25 Acc/Clar): the "5×100=500 lines" worked example is the dramatic version; for many engineers the "every downstream re-parses the same SQL → Trino planner cost" framing matters more than line-count. Resource-faithful, no fix.

---

## Q2 — string_agg → Trino (4.8125 PASS)

**Acc 4.75 / Clar 4.75 / Prac 5.0 / Compl 4.75.**

The canonical Trino-equivalent answer:
- Trino has NO `string_agg` (Postgres-only) — correct per pin `reference_trino_listagg_native`.
- Trino HAS native `listagg(expr, sep) WITHIN GROUP (ORDER BY ...)` — verified at [trino.io aggregate.html](https://trino.io/docs/current/functions/aggregate.html); confirmed in 467 + all recent versions.
- Worked example correctly uses `WHERE occurred_at >= current_date - interval '90' day` (Trino 467 INTERVAL `'90' day` form is correct per pin `reference_trino_interval_qualifiers`; day is a valid qualifier).
- `listagg(sku, ', ') WITHIN GROUP (ORDER BY sku) GROUP BY customer_id` — exact canonical shape.
- Defangs listagg-as-window-function: "listagg is an AGGREGATE not a window function; listagg() OVER() errors/doesn't exist" — verified at [trinodb/trino #16982 "Improve error message for LISTAGG window function"](https://github.com/trinodb/trino/issues/16982): "LISTAGG currently can't be used as a window function."
- Provides the correct windowed alternative: `array_join(array_agg(x ORDER BY x) OVER (PARTITION BY ...), ', ')` for cases where engineer needs the same comma-string in a window context (e.g., one row per account but also wants a running list).

No imported-prior (correctly identifies listagg AS present in Trino — does not fall into the assumed-absence trap that has bitten 9 times: starts_with/to_char/listagg/array_sum/format_number/migrate/LATERAL/MERGE-WHEN-MATCHED-AND/etc; pin `reference_trino_listagg_native` exists exactly because of an earlier assumed-absence miss). No broken-secondary, no over-warning, no fabrication. Engineer can copy-paste both forms.

**Action**: per-instance clean PASS, no fix.

---

## Q3 — write.distribution-mode small files (4.0 PASS — completeness gap)

**Acc 4.5 / Clar 4.5 / Prac 3.5 / Compl 3.5.**

### Hash-is-default — VERIFIED CORRECT
Responder claims hash is the default on Iceberg 1.5.2. Resource r13 §4133 teaches "hash is the DEFAULT since Iceberg 1.2.0/Spark 3.3" — resource-faithful.

**Verified independently** at:
- [apache/iceberg PR #6828 "Spark 3.3: Change default distribution modes"](https://github.com/apache/iceberg/pull/6828) — "the default distribution mode for partitioned but unsorted tables in INSERT being HASH (instead of NONE)" landed in Iceberg via this PR;
- [Medium — Iceberg & Writing Distribution Modes in Spark](https://medium.com/@deepa.account/a-note-on-iceberg-and-writing-distribution-modes-in-spark-3b1000be8003) — "starting in Iceberg 1.2.0, Iceberg requests that Spark pre-sort data through the table property write.distribution-mode with the value hash."

So the responder's hash-default claim AND the modes (hash/none/range) mechanism are accurate.

### Completeness gap — frequent small commits + compaction
**This is the load-bearing gap.** If hash is already the default on Iceberg 1.5.2 + Spark 3.3, the engineer's "hundreds of tiny files (<1MB) after dbt loads" is most likely NOT caused by `write.distribution-mode=none` (that would only apply if the table explicitly overrode the default).

The dominant root cause for tiny-files-after-dbt-runs is **frequent small commits**: each dbt incremental run commits at least one data file per partition touched. Over many small batches (hourly / 15-min runs), each partition accumulates many small files even with hash distribution. Distribution-mode is a fanout-prevention knob (prevents ONE write from fanning out small files across many partitions) — it does NOT consolidate the per-commit residual files that pile up across many runs.

The real fix:
1. **Compaction**: `ALTER TABLE iceberg.schema.table EXECUTE optimize(file_size_threshold => '128MB')` (Trino-native, this stack's preferred path per pin `reference_trino_optimize_clears_position_deletes`) OR `CALL iceberg.system.rewrite_data_files(...)` from Spark. Schedule as a dbt macro or k8s cronjob.
2. **Per-table write target**: `write.target-file-size-bytes=134217728` (128MB) — responder mentions this.
3. **Reduce commit frequency** if possible: batch dbt incrementals from 15-min to hourly/daily.
4. (Distribution-mode is a non-issue if already on hash default.)

Responder mentions `write.target-file-size-bytes=128MB` (item 2) but does NOT lead with compaction (item 1) or address commit-frequency (item 3). Distribution-mode mechanism is correct but is the wrong primary lever for this scenario.

This is a verifiable completeness gap — not a factual error. The distribution-mode answer the responder gave IS the textbook answer for *certain* small-files causes (fanout with `none`), but the framing implies that "hundreds of tiny files after dbt loads to Iceberg" is fanout-caused, when the more common cause on this stack is commit-frequency. The engineer would walk away thinking "check if distribution-mode is none, set hash, done" and miss the compaction step that actually resolves their existing pile.

### FIX-A decision — **NO IMMEDIATE FIX-A; SOFT WATCH**

Resources already document the compaction angle (r13 §2862 ALTER TABLE EXECUTE optimize, r28 §297 dbt + maintenance, pin `reference_trino_optimize_clears_position_deletes`). This is a routing/emphasis miss, not a content gap. r13 §4133 hash-is-default content is accurate.

**NEW SOFT WATCH `iter1290-Q3 small-files-after-dbt-loads root-cause routing: distribution-mode vs commit-frequency-compaction`** — re-probe in 4-8 iters under "small files after frequent dbt runs / how do I compact" framings WITHOUT the "what does distribution-mode do" lead. If responder again routes to distribution-mode and under-emphasizes compaction under non-distribution-mode-led framings, escalate to LIGHT FIX-A adding a "WHY do dbt loads produce small files" routing card at the small-files keyword zone — distribution-mode = fanout cause, commit-frequency = accumulation cause, compaction = the fix for accumulation.

Pattern reference: this is analogous to iter1289-Q2 position-delete Spark-vs-Trino-optimize routing watch (also a routing/emphasis miss with correct base content). Don't churn the resources before establishing a pattern across 2+ probes.

---

## Q4 — Oracle || NULL → Trino (4.875 PASS)

**Acc 5.0 / Clar 4.75 / Prac 5.0 / Compl 4.75.**

Crisp, accurate, and copy-paste-ready answer:

- **Oracle's || treats NULL as empty string** — correct, the historical Oracle idiosyncrasy ("Oracle treats empty string '' as NULL but `||` with NULL operand returns the other operand"). `'John'||NULL||'Doe'='JohnDoe'` is verified Oracle behavior.
- **Trino's || returns NULL if any piece is NULL** — correct, SQL-standard NULL-propagation. Verified at [trino 467 string.md](https://github.com/trinodb/trino/blob/467/docs/src/main/sphinx/functions/string.md): `concat` "provides the same functionality as the SQL-standard concatenation operator (`||`)" — and SQL-standard is NULL-propagating. The 3-NULL behavior `'John'||NULL||'Doe'` returns NULL in Trino — engineer's Oracle code would silently produce NULL rows after migration.
- **Fix: `COALESCE(col, '')` wrap each piece** — correct canonical fix.
- **Alternative: `concat_ws(' ', first_name, last_name, '(' || account_code || ')')` "automatically skips NULL"** — verified at [trino.io 467 string.html](https://trino.io/docs/467/functions/string.html): "Any null values provided in the arguments after the separator are skipped." `concat_ws(sep, ...)` is the cleaner-for-many-pieces alternative.

Caveat the responder correctly nuances: `concat_ws` skips NULL ARGUMENTS but the SEPARATOR is fixed (a space here). The engineer's specific shape `first_name || ' ' || last_name || ' (' || account_code || ')'` has parenthetical wrapping that `concat_ws` won't directly reproduce — so for the exact format `COALESCE` is more faithful, while `concat_ws` is cleaner if the engineer can live with `'John Smith ACC-001'` instead of `'John Smith (ACC-001)'`. Responder cleanly delivers both options.

No imported-prior, no broken-secondary, no over-warning, no fabrication. Clean answer.

**Action**: per-instance clean PASS, no fix.

---

## Summary across the 4 questions

**Pattern this iter**: Massive recovery from iter1289 3.547 (with Q3 1.5 FAIL). iter1289 FIX-A (r27 §3 ephemeral QUICK-ANSWER canonical + r28 §3.3 cross-ref) **REACHED on 1st re-probe** — Q1 4.8125 clean PASS, HARD WATCH closes. Q2 + Q4 are textbook clean PASSes. Q3 is a completeness gap, not a factual error — distribution-mode mechanism explanation is correct and resource-faithful, but the root-cause routing for "tiny files after dbt runs" misses the dominant commit-frequency + compaction angle. Soft watch only; no resource fix until pattern confirms across 2+ probes.

**Watches**:
- **CLOSE**: `iter1289-Q3 dbt ephemeral-basics findability reach-test` (FIX-A REACHED 1st re-probe).
- **NEW SOFT**: `iter1290-Q3 small-files-after-dbt-loads root-cause routing: distribution-mode vs commit-frequency-compaction` (re-probe 4-8 iters under non-distribution-mode-led framings).
- **CARRY SOFT**: `iter1289-Q2 position-delete Spark-vs-Trino-EXECUTE-optimize routing` (4-8 iters).
- **CARRY SOFT**: `iter1289-Q4 LPAD/RPAD false-divergence` (4-8 iters).
- **CARRY SOFT**: `iter1288-Q1 COUNT(*)-slow canonical reach-test` (4-6 iters).

**No FIX-A this iter.** All required topics remain PASSED.

**FIX-A nature note**: 2 consecutive 1st-re-probe FIX-A REACHes (iter1271→1272 bloom-CREATE-467 + iter1289→1290 ephemeral-basics) confirm the QUICK-ANSWER-canonical-with-explicit-question-shape-anchors-at-keyword-zone pattern (option A from iter1289 feedback) is reliably effective. Continue using this pattern for future findability misses where content exists but routing fails.
