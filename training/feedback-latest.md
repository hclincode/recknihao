# Iter 1273 — Judge Feedback

**Overall: 3.875 PASS** (Q1 4.625 / Q2 2.375 / Q3 3.75 / Q4 4.75)

A mixed iteration that drops from iter1272's 4.625. **Q2 is a real accuracy FAIL** — responder misread the engineer's stated requirement and confidently rejected the textbook-correct `ROLLUP(region, plan_tier)` answer, recommending instead `GROUPING SETS((region),(plan_tier),())` which drops the detail grain the engineer explicitly asked for and adds plan-tier-only rows the engineer did NOT ask for. **Q1 is a strong PASS that lifts the thinnest topic** (query-performance-basics): the EXPLAIN ANALYZE fragment-order and field-name claims (Fragment 0 = output/coordinator, Scheduled / CPU / Blocked / Input avg. / Input std.dev. / Physical Input) all verify against trino.io/docs/467. **Q3 is a real findability gap**: r27 §6.7B already has a pin-perfect dbt source freshness canonical (verified at iter1235 5.0 / iter1195 5.0 / iter1142 5.0) — the responder failed to find it from this question's keywords and instead hedged "not enough info" + deferred to docs.getdbt.com. **Q4 clean PASS.**

---

## Per-question scores

### Q1 — 3-table Iceberg join EXPLAIN ANALYZE fragment-order + where-time-spent metrics (THIN-TOPIC PROBE)

**Score 4.625** (Acc 4.5 / Clar 4.5 / Prac 5.0 / Compl 4.5)

Responder: Fragments listed top-to-bottom in textual output (Fragment 0 = output/coordinator, Fragment 1+ = source/intermediate); data actually flows leaf→root so Fragment 0 collects last. Diagnostic loop: compare Scheduled vs CPU per operator — Scheduled ≈ CPU means compute-bound (fix join order / pre-filter), Scheduled >> CPU (5-10×) means I/O-bound (check Blocked: Input, Physical Input). Watch `Physical Input` (actual bytes from MinIO) vs expected — 100× high = pruning broke. Watch `Input std.dev. (%)` > 80% = skew. Said `Wall time` / `Files:` don't exist in 467 output; wall-clock ≈ Scheduled. Worked example: Scheduled 450s / CPU 15s / Physical Input 50GB vs expected 2GB → pruning broke, fix WHERE not add workers.

**Verification (WebFetch [trino.io/docs/467/sql/explain-analyze.html](https://trino.io/docs/467/sql/explain-analyze.html) + WebSearch):**
- Per-fragment metrics shown: **CPU**, **Scheduled**, **Blocked** (with Input/Output breakdowns), **Input** (rows + size, per-task average and standard deviation), **Output** (rows + size), Output layout, Output partitioning. All match responder's field-name claims.
- Per-operator `Physical Input: 4.51MB` is verified as a canonical metric (per the iter1258 verification pin and PR #23874).
- Fragment 0 [SINGLE] = root/output fragment, runs on a single node (typically coordinator). Confirmed via search result + trinodb/trino#4720 ("EXPLAIN ANALYZE removes top stage"). Responder's "Fragment 0 = coordinator, collects last" is correct.
- `Wall time` / `Files:` are NOT documented fields of Trino 467 EXPLAIN ANALYZE output — responder's "don't exist in 467 output" defang is accurate.
- "wall-clock = Scheduled" — slight oversimplification (Scheduled is task-actively-scheduled time, very close to wall-clock for a 7-10 min query well past noise floors but not strictly identical for tiny queries with GC pauses) — defensible at the engineer's 8-10 min query scale; iter1258 also flagged this minor imprecision.

**The diagnostic loop is genuinely actionable**: the engineer can ctrl-F these exact metrics in their own output, pick the highest-Scheduled fragment, read the Scheduled-vs-CPU split + Physical Input + Input std.dev., and know whether to fix WHERE (pruning), add a hash-key (skew), or restructure the join (compute-bound). The worked example with concrete numbers (450s / 15s / 50GB vs 2GB) gives a copyable mental template.

Minor -0.5 Accuracy: nothing wrong, but the responder framed "Scheduled >> CPU (5-10×) → I/O-bound" as a clean binary when in real plans high Scheduled/CPU also happens with upstream-fragment-waiting (probe blocked waiting on a slow build, dynamic filter still being computed, exchange backpressure) — not always disk I/O. Worth a tiny hedge. Minor -0.5 Compl: didn't surface `EXPLAIN ANALYZE VERBOSE` for per-operator percentile breakdowns when std.dev. signals skew (the natural next-step) or the `dynamicFilterSplitsProcessed` ctrl-F (iter1256 canonical) when fragment is a TableScan on a star join.

No imported-prior, no broken-secondary, no over-warning, no fabrication. Lifts the thinnest topic (query-performance-basics) +0.0102.

---

### Q2 — Subtotal report: detail (region, plan_tier) + per-region subtotal + grand total — REAL ACCURACY MISS

**Score 2.375** (Acc 1.5 / Clar 4.0 / Prac 1.5 / Compl 2.5)

**LOAD-BEARING ACCURACY MISS — wrong grouping sets selected AND the correct ROLLUP answer was confidently REJECTED.**

The engineer's stated requirement, read literally:
- (a) "revenue by region AND by plan tier" = **detail grain `(region, plan_tier)`** — every (region, plan_tier) combination as a row.
- (b) "subtotal rows for EACH REGION across all plan tiers" = **per-region subtotal `(region)`** — one row per region totaling across all plan tiers.
- (c) "one grand-total row" = **`()`** — single row summing everything.

That is **exactly `ROLLUP(region, plan_tier)`** = `GROUPING SETS ((region, plan_tier), (region), ())`.

**Responder recommended `GROUP BY GROUPING SETS ((region), (plan_tier), ())` and explicitly rejected ROLLUP** with the justification "ROLLUP(region, plan_tier) drops the by-plan_tier-only rows — you'd miss the plan-tier breakdown." This misreads the ask: the engineer's "by region AND by plan tier" means the (region, plan_tier) DETAIL grain, NOT a separate plan-tier-only breakdown. The responder's chosen grouping sets:
- **OMIT** the (region, plan_tier) detail rows entirely — the engineer's primary deliverable, GONE.
- **ADD** (plan_tier)-only rows the engineer did NOT ask for — clutter.
- **CORRECTLY** include (region) and () — but those are the supporting rows, not the deliverable.

Result: engineer pastes the recommended query and the report has no by-(region, plan_tier) cells at all — the very thing they need to display in the MRR report.

**Verification (WebFetch [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html)):**
- "`ROLLUP(region, plan_tier)`" expands to `GROUPING SETS ((region, plan_tier), (region), ())` verbatim.
- "ROLLUP does NOT produce (plan_tier) alone. The hierarchy flows from most detailed to most aggregated, following the column order specified."
- This is fundamentally different from CUBE, which would generate every combination including (plan_tier).

**The correct answer also exists in resources, unambiguously**, at r28 §419+ "LEADING CANONICAL — Trino GROUPING SETS / ROLLUP / CUBE":
- L426: *"'detail + subtotals down a group hierarchy + grand total' (e.g. per-(region, product) detail, then a per-region subtotal, then the overall total — NO per-product-only row) → ROLLUP(region, product)"* — this is the engineer's question verbatim.
- L447-449 shows `GROUP BY ROLLUP(region, product)` worked example with "(region, product) detail rows + a per-region subtotal row + one grand-total row."

The responder appears to have grabbed the **adjacent** decision-matrix branch at r28 L483-499 ("subtotals on BOTH dimensions → CUBE") which describes the WRONG scenario for this ask — and then somehow inverted CUBE-rejection logic into a ROLLUP-rejection.

**Classification: responder synthesis miss + confident-rejection-of-correct-answer.** Mechanism (GROUPING SETS syntax, column-names-only rule, ORDER BY CASE row-type sort, GROUPING() bitmask 0/1/2/3) is correct. Set SELECTION is wrong AND the responder explicitly steered the engineer AWAY from the correct ROLLUP. The "X drops the by-Y-only rows — you'd miss the Y breakdown" justification is the same shape as r28 L483-499's CUBE-vs-ROLLUP defang, applied to the wrong axis.

Acc 1.5: mechanism correct, sets wrong, confident rejection of the right answer. Prac 1.5: engineer copy-pastes and gets a report missing the entire detail grain. Clar 4.0: well-explained, just wrong. Compl 2.5: ORDER BY + GROUPING() labels covered, but the core deliverable is missing.

**NO FIX-A WARRANTED.** r28 §419-449 already has the exact correct ROLLUP canonical with the engineer's question shape verbatim in the keyword anchors at L423. This is a responder routing slip — the responder navigated to the ROLLUP-vs-CUBE adjudication branch (r28 L483-499) which is the wrong sub-section for this ask, instead of the L426/L447 "detail + per-X subtotal + grand total → ROLLUP" branch. Per `feedback_synthesis_ceiling_stop_churning.md` + `feedback_new_card_over_attracts_adjacent.md` — adding another ROLLUP-attractor risks over-attracting CUBE-territory questions. The L423 keyword anchors already list "replace three separate UNION ALL'd GROUP BY queries" verbatim (which is literally Q2's framing) — the resource attractor is already in place; this is a 1st-instance routing slip.

**NEW WATCH `iter1273-Q2 ROLLUP-rejected-in-favor-of-non-hierarchical-GROUPING-SETS`**: re-probe within 4-8 iters with framings that have the exact `(detail by two dims) + (per-first-dim subtotal) + (grand total)` shape, especially when paired with "replace 3 UNION ALL queries" or "one query for MRR by region and plan tier". If recurs under 2+ different framings → escalate to LIGHT FIX-A reconciling r28 §419-449 with a tightened "WHICH grouping operator" router at the top + co-located defang of the responder's exact wrong-set ((region),(plan_tier),()) pattern. Pattern family: imported-prior (responder grabbed the CUBE-vs-ROLLUP defang justification and misapplied it).

No fabrication; no over-warning. Cites r28.

---

### Q3 — dbt source freshness for Kafka-written raw Iceberg (FINDABILITY GAP — resource exists, responder didn't reach it)

**Score 3.75** (Acc 4.5 / Clar 4.0 / Prac 3.5 / Compl 3.0)

**Genuine findability gap, NOT a content gap.** Resource exists; responder couldn't reach it from this question's keywords.

Responder HEDGED "I don't have enough info to answer well" — but then gave the **correct partial shape**: declare the Kafka-written table as `source()` in `sources.yml`; configure `freshness:` with `loaded_at_field:` + `warning_after:` / `error_after:` thresholds; run `dbt source freshness` in orchestration before dashboard refresh. Said resources only have "a passing mention of dbt source freshness check on ephemeral models in resource 28." Deferred to docs.getdbt.com/docs/build/sources for exact YAML.

**Verification (WebFetch [docs.getdbt.com/docs/build/sources](https://docs.getdbt.com/docs/build/sources)):**
- Exact YAML: `freshness: warn_after: {count: 12, period: hour}, error_after: {count: 24, period: hour}` under `config:` block at source or table level, with `loaded_at_field: <timestamp_column>`. Confirmed.
- `period` enum = minute | hour | day only (no week/quarter/second). Confirmed.
- Command = **`dbt source freshness`** (separate CLI command). Confirmed.
- **NOT** automatically run by `dbt run` or `dbt build`. Confirmed verbatim.
- `warn_after` → warning status (non-blocking); `error_after` → error status (non-zero CLI exit for CI gating). Confirmed.
- Output to `target/sources.json` for tooling.
- Responder's partial shape is fully consistent with the docs.

**Resource grep — content EXISTS at r27 §6.7B (lines 3179-3251+):**
The full canonical is there: keyword anchors at §6.7B header verbatim include "How do I declare source freshness in dbt?" / "What command runs the freshness check?" / "Does a stale source fail my `dbt run` / `dbt build`?" — literally Q3's three sub-questions. Worked example at L3248-3251 shows the exact YAML with `loaded_at_field: ingested_at`, `warn_after: {count: 12, period: hour}`, `error_after: {count: 24, period: hour}`. L3203-3216 covers the `dbt source freshness` command + "NOT included in dbt build" caveat verbatim. L3218-3231 covers the "freshness failure does NOT auto-block downstream" + operational CI gating pattern.

This same canonical was reached pin-perfectly at iter1235 (5.0), iter1221 (5.0), iter1195 (5.0), iter1142 (5.0) — the topic line shows 4.6225/12 PASSED with comfortable margin. The responder's hedge in iter1273 is a **findability regression** under one specific question framing.

**What likely caused the routing miss**: this question's keyword surface is "Kafka-written raw Iceberg / pipeline falls behind / dbt run succeeds but source is 6+h stale / no visible error / can dbt declare expected source freshness." That's a problem-narrative framing ("my data is stale, can dbt detect it?") rather than a feature-name framing ("how does dbt source freshness work?"). The r27 §6.7B keyword anchors are feature-name-shaped ("source freshness", "loaded_at_field", "dbt source freshness command"). The narrative-shaped framing doesn't hit those anchors.

**Acc 4.5**: every fact the responder DID surface is correct (sources.yml, freshness block, loaded_at_field, warn_after/error_after, separate command, doesn't auto-run). **Prac 3.5**: the partial shape is enough for the engineer to look up the exact YAML themselves at docs.getdbt.com, but they have to do the lookup rather than copy-paste from the response. **Compl 3.0**: the engineer's question has 3 sub-asks (can dbt detect / how to declare / how to fail or warn) and all 3 are touched but none are delivered with a paste-and-run YAML. **Clar 4.0**: the hedge ("not enough info to answer well") is messier than a confident partial answer would have been.

**RECOMMEND LIGHT FIX-A: add a narrative-shaped attractor in r27 §6.7B (or as a new findability card cross-referenced from r13/r28).** Specifically, add keyword-anchor language matching the problem narrative:
- "Kafka pipeline silently fell behind / Spark ingest stopped writing / data is X hours stale / dbt run still succeeds on stale data / how does dbt detect upstream pipeline lag" → route to §6.7B.
- "no visible error in dbt / dbt run passes but data is old / silent staleness" → route to §6.7B.

The reason for the FIX-A despite the content existing: this is the SECOND occurrence (this iter is the first known regression on a topic that has been 4-times-pin-perfect; iter1142/1195/1221/1235 all reached at 5.0 under feature-name framings). One narrative-shaped reframing tripped the routing. Adding 6-12 lines of problem-narrative keyword anchors at r27 §6.7B costs little and protects against this narrative-shape regression family. Location: `r27 §6.7B` opening keyword-anchor block, ADD problem-narrative shapes alongside the existing feature-name anchors. Cross-ref FROM `r13` (Kafka/Postgres-to-Iceberg ingestion topic, line for source-freshness check) TO `r27 §6.7B`.

Pattern family: `feedback_responder_findability.md` — Haiku finds answers by keyword→resource matching; the content was placed where it's topically correct (r27 dbt section) but the question's keywords ("Kafka", "raw Iceberg", "pipeline behind", "silently stale") don't lead there. Cross-ref + narrative-shaped anchors are the fix.

**NEW WATCH `iter1273-Q3 source-freshness narrative-shaped framing findability gap`**: re-probe within 2-4 iters with similar problem-narrative framing ("X pipeline silently fell behind, dbt didn't notice", "raw table X hours stale, dbt run passes"); if responder again hedges/defers despite r27 §6.7B content, FIX-A is mandatory.

No imported-prior, no broken-secondary, no fabrication.

---

### Q4 — Oracle `''=NULL` semantics broke after Trino port — IS NULL no longer catches '' (CLEAN PASS)

**Score 4.75** (Acc 5.0 / Clar 4.5 / Prac 5.0 / Compl 4.5)

Pin-perfect Oracle-empty-string-vs-Trino diagnosis + fix. Responder: explained Oracle treats `'' = NULL` (a documented Oracle quirk, not standard SQL); Trino follows the SQL standard and keeps `''` distinct from NULL; the migrated `WHERE notes IS NULL` now misses rows that were `''` in the source. Two fix patterns:
- **Pattern A (preferred — normalize at ingest)**: in the dbt staging/landing model, `CASE WHEN notes = '' THEN NULL ELSE notes END` or `NULLIF(notes, '')` — pushes Oracle-compatibility into a single layer, downstream `IS NULL` predicates work natively.
- **Pattern B (treat both same at query time)**: `WHERE col IS NULL OR col = ''` everywhere, or `COALESCE(NULLIF(notes, ''), 'Unknown')` if a default placeholder is preferred.

Migration audit checklist: grep the Oracle codebase for `IS NULL` / `NVL(` / `DECODE(col, NULL, ...)` / `= ''` on string columns; test row-count parity between Oracle and Trino with both empty-string-as-NULL and empty-string-distinct semantics to find slip-through cases.

**Verification (WebFetch + canonical SQL-standard knowledge):**
- Trino follows SQL standard: `''` (empty string) is a valid distinct value of VARCHAR type, NOT equal to NULL. Confirmed; this is universal across Trino, Postgres, MySQL, SQL Server. Oracle is the outlier.
- `NULLIF(col, '')` → returns NULL when col equals '', else returns col. Standard SQL semantics, supported on Trino 467 (function listing in [trino.io/docs/467/functions/conditional.html](https://trino.io/docs/467/functions/conditional.html)).
- `COALESCE(NULLIF(notes, ''), 'Unknown')` → idiomatic Trino, works as described.
- `WHERE col IS NULL OR col = ''` → correct Trino predicate, no issues.

Production-stack-correct for on-prem Trino 467 + dbt + Iceberg: Pattern A in the dbt staging layer is the right architectural recommendation (single source of compat, downstream models don't have to repeat the OR).

Minor -0.5 Compl: could have mentioned `TRIM(col) = ''` for whitespace-only strings (separate edge case — `'   '` is empty after trim, distinct from `''` and from NULL even on Trino), and could have flagged `LENGTH(col) = 0` as a synonym for `col = ''`. Neither is the load-bearing piece for Q4 as asked. -0.25 Clar: could have led with a 1-line root-cause statement before the fix patterns.

**Acc 5.0** every load-bearing fact correct, no imported-prior, no over-warning, no fabrication. Cites r27 §4.1.

---

## Explicit adjudications (judge findings)

**(1) Q2 — Is `ROLLUP(region, plan_tier)` the correct fit, and is the responder's GROUPING SETS selection + confident ROLLUP rejection a REAL accuracy miss?**

**YES on both counts.** `ROLLUP(region, plan_tier)` = `GROUPING SETS ((region, plan_tier), (region), ())` is the EXACT match for the engineer's requirement: detail by (region, plan_tier) + per-region subtotal + grand total. Verified at trino.io/docs/467/sql/select.html. The responder's chosen `GROUPING SETS((region),(plan_tier),())` OMITS the (region, plan_tier) detail grain that the engineer's first deliverable explicitly requires AND adds (plan_tier)-only rows the engineer did not ask for. The confident rejection of ROLLUP with the "you'd miss the plan-tier breakdown" justification misreads "by region AND by plan tier" as needing separate plan-tier-only rows when it actually means the (region, plan_tier) detail cells. This is a real accuracy miss: mechanism (GROUPING SETS syntax) is correct, but set selection is wrong AND the engineer is actively steered AWAY from the correct answer. r28 §419+ already has the right canonical (L426/L447) — the responder routed to the adjacent CUBE-vs-ROLLUP adjudication block (L483-499) instead.

**(2) Q3 — Is this a genuine content/findability gap warranting a dbt-source-freshness FIX-A, and where should it go?**

**FINDABILITY gap, not content gap.** Content EXISTS at r27 §6.7B (lines 3179-3251+) with the full YAML, command, "doesn't auto-run" caveat, and worked example — and has been pin-perfectly reached at iter1142/1195/1221/1235 (all 5.0). The iter1273 regression is the first known one on this topic and is triggered by the problem-narrative framing ("Kafka pipeline silently fell behind / dbt run passes on stale data") not matching the §6.7B feature-name keyword anchors. **RECOMMEND LIGHT FIX-A**: add narrative-shaped keyword anchors at r27 §6.7B opening (and a cross-ref from r13's Postgres-to-Iceberg / streaming-ingest section pointing TO §6.7B for source-freshness checks). Add ~10 lines max — anchor phrases like "Kafka pipeline silently fell behind", "data is X hours stale dbt run passes", "no visible error on stale source", "raw table written by Spark is N hours old", "Iceberg source has not been updated", "dbt didn't detect upstream lag". This addresses the narrative-vs-feature-name routing gap without churning the §6.7B canonical itself (which has been 4× pin-perfect under feature-name framings).

**(3) Q1 — Are the EXPLAIN ANALYZE field names + fragment-order claims accurate for Trino 467?**

**YES, all accurate.** Verified at trino.io/docs/467/sql/explain-analyze.html and via WebSearch:
- Fragment 0 [SINGLE] = root/output fragment, runs on a single node (typically coordinator) — responder's "Fragment 0 = coordinator, collects last" is correct.
- Fragments listed in numeric (top-to-bottom) order in the textual output — responder's "fragments top-to-bottom" is correct for display order; data flows leaf→root (Fragment 0 collects last) is also correct.
- Per-fragment metrics: CPU, Scheduled, Blocked (with Input/Output breakdowns), Input (rows + size, per-task average and standard deviation), Output (rows + size), Output layout, Output partitioning — all match responder's field names.
- Per-operator `Physical Input: 4.51MB` is a documented metric (PR #23874, iter1258 verification).
- `Wall time` / `Files:` are NOT documented fields — responder's "don't exist in 467 output" defang is accurate.
- "wall-clock ≈ Scheduled" is a defensible heuristic at 8-10 min query scale (well past noise floors); the docs hedge "the relative cost of the plan nodes is based on wall time, which may or may not be correlated to CPU time" but for the engineer's stated 8-10 min query the equivalence is fine.
- The Scheduled-vs-CPU ratio diagnostic (≈1 = compute-bound; >>1 = I/O-bound / blocked) matches the iter1258 verification.

**(4) New watches and pattern observations:**

- **NEW WATCH `iter1273-Q2 ROLLUP-rejected-in-favor-of-non-hierarchical-GROUPING-SETS`** — re-probe within 4-8 iters with `(detail by 2 dims) + (per-first-dim subtotal) + (grand total)` framings, especially "replace 3 UNION ALL queries" / "MRR by region and plan tier". If recurs under 2+ framings → LIGHT FIX-A reconciling r28 §419-449 with a tightened WHICH-operator router + co-located defang of the wrong-set ((X),(Y),()) pattern.
- **NEW WATCH `iter1273-Q3 source-freshness narrative-shaped framing findability gap`** — re-probe within 2-4 iters with problem-narrative framing ("X pipeline silently fell behind / dbt run passes on stale data / raw table N hours old"). If responder again hedges/defers despite r27 §6.7B content, the LIGHT FIX-A (narrative-shaped anchors at §6.7B opening + r13 cross-ref) is MANDATORY.
- **CARRY SOFT iter1272-Q3 dbt-unit-tests-free-tier-hallucination** — un-probed this iter; carry forward.
- **CARRY SOFT iter1271-Q2 current-vs-longest-streak** — un-probed this iter; carry forward.
- **CARRY SOFT iter1270-Q1 PRIMARY-KEY-in-CREATE** — un-probed this iter; carry forward.
- **Pattern observation**: Q2 is the second time this loop a responder has grabbed a defang from an ADJACENT decision-matrix branch and misapplied it (pattern family: imported-prior within resources/). The r28 ROLLUP-vs-CUBE adjudication is structurally correct, but the responder synthesized a CUBE-style "drops by-Y-only rows" justification against ROLLUP, applied to a different axis than the matrix intends. The fix (if Q2 recurs) is not a new card but a tightened TOP-OF-MATRIX router that forces the responder to read the requirement first before reading any adjudication block — same pattern as iter951-956 gaps-and-islands tightening.

---

## Topic score history updates

- **Query performance basics: partitioning, indexing strategy for analytics** — Q1 4.625 → 4.1353/41 to 4.1469/42 (+0.0116, margin +0.6469, still thinnest required topic but lifts steadily).
- **Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL** — Q2 2.375 → 4.4961/199 to 4.4855/200 (-0.0106, margin +0.4855, comfortably above threshold; first FAIL on this topic in many sweeps).
- **dbt sources / source freshness** — Q3 3.75 → 4.6225/12 to 4.5554/13 (-0.0671, margin +1.0554, comfortable; first sub-4 score on this topic since iter1141 and the only one in the last 8 probes).
- **Oracle PL/SQL procedure → dbt + Trino SQL migration** — Q4 4.75 → 4.5061/241 to 4.5071/242 (+0.0010, margin +1.0071).

Overall iter1273: **3.875 PASS** (down from iter1272's 4.625; Q2 dragged the iteration).
