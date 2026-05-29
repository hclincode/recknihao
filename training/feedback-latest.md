# Judge Feedback — Iter 370 Q1 (Trino federation, 15th-iter angle)

**Question**: "We JOIN our 1B-row Iceberg events to two Postgres tables (500K customers + 50K products). Each join alone works fine but all three OOM. How does Trino execute a three-table join and what do we do?"

**Score: 3.375 — FAIL** (below per-question 4.0 bar; below federation topic's 4.5 STRONG-PASS bar)

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3.0 | MAJOR: `ANALYZE postgresql.public.customers` from Trino is not supported by the JDBC PostgreSQL connector — instruction fails verbatim. MINOR: `Join[BROADCAST]` is not the canonical Trino EXPLAIN annotation. |
| Beginner clarity | 3.5 | CBO/BROADCAST/PARTITIONED/build-side/probe-side/dynamic-filtering used without inline definitions. 14th iteration of the same glossary gap in `resources/22`. |
| Practical applicability | 3.5 | Fix 1 instruction fails as typed; rest of the ladder (session properties + CTAS into Iceberg) is actionable. No on-prem k8s or Trino 467 version context. |
| Completeness | 3.5 | Skipped the conceptual core (how Trino executes the three-table join — left-deep tree, CBO ordering, intermediate-result sizing as OOM root cause). Missed DF role in pruning Iceberg events scan, missed `join_max_broadcast_table_size` threshold, missed concurrency-cap stop-gap. |

---

## What went well

- **Tiered fix ladder structure** (Fix 1 stats/CBO → Fix 2 PARTITIONED → Fix 3 durable Iceberg ingestion) matches the iter360-369 progression that has worked on this topic. The escalation framing is correct.
- **`join_reordering_strategy = 'AUTOMATIC'` + `join_distribution_type = 'PARTITIONED'`** are the right session-property names and values.
- **CTAS + daily INSERT INTO Iceberg as the durable fix** is well-aligned with the on-prem k8s / Trino 467 / Iceberg 1.5.2 production stack and the 14-iteration federate-vs-ingest decision tree in `resources/22`.
- **Anchoring the recommendation on dynamic filtering** (`enable_dynamic_filtering = true` check) carries the right reflex from the iter369 Q1 DF deep-dive into a three-table scenario.

## What broke

### CRITICAL — Correctness regression on the ANALYZE direction

The responder told the user to run `ANALYZE` on Postgres tables **in Trino** + `SHOW STATS` to confirm row_count is populated. This is factually wrong for the JDBC PostgreSQL connector.

Per [PostgreSQL connector — Trino 481 Documentation](https://trino.io/docs/current/connector/postgresql.html): "To collect statistics for a table, execute the following statement in PostgreSQL. `ANALYZE table_schema.table_name;`"

The Trino PostgreSQL connector **reads** stats that Postgres has already collected — ANALYZE through Trino's catalog interface is not supported for the JDBC connector. The correct sequence is:

1. Connect to the source Postgres DB (psql or admin tool) and run `ANALYZE public.customers; ANALYZE public.products;` against Postgres directly.
2. In Trino, run `SHOW STATS FOR postgresql.public.customers` to verify the connector now reports a non-null `row_count` and non-null `distinct_values_count` for the join key.
3. Then `SET SESSION join_reordering_strategy = 'AUTOMATIC'` so the CBO uses the freshly available stats.

**This is the same gap iter370 teacher action #4 was supposed to close** (from iter369 Q1 completeness deduction). The action did not land in `resources/22`, so the responder repeated the iter369 carry-forward error in the iter370 probe. Single highest-leverage fix for iter371.

### MINOR — EXPLAIN annotation token is wrong

Responder said to look for `Join[BROADCAST]` annotations in EXPLAIN. Per [EXPLAIN — Trino 480 Documentation](https://trino.io/docs/current/sql/explain.html), the canonical tokens are:

- `join (INNER, REPLICATED)` for broadcast joins
- `join (INNER, PARTITIONED)` for hash-redistributed joins
- `Exchange[REPLICATE]` for the adjacent exchange node that copies the build side

A user who runs EXPLAIN and `grep` for `Join[BROADCAST]` will find nothing. Strike the `Join[BROADCAST]` / `Join[PARTITIONED]` references from `resources/22` and replace with the canonical tokens.

### Conceptual core missed — "how does Trino execute a three-table join"

The question explicitly asks for the execution model. Responder went straight to fixes without explaining:

- Trino builds a **left-deep join tree** for multi-way joins.
- The CBO picks **join order** based on row counts and selectivity (smallest filtered side first).
- Each join independently chooses **BROADCAST or PARTITIONED**.
- The **intermediate result** of join 1 (events ⨝ products) becomes the probe side of join 2 (intermediate ⨝ customers) — and that intermediate result's size, not the source-table sizes, is usually what drives the OOM.
- This is why "each join alone works fine but all three OOM" — single joins fit in memory but the broadcasted intermediate result for the second join blows the per-node limit.

This conceptual section is the **load-bearing answer to the user's "how does" question** and the responder skipped it entirely.

### Continued glossary gap (14th iteration)

`resources/22` still does not inline-define: CBO, BROADCAST, PARTITIONED, build side, probe side, left-deep join tree, dynamic filtering. Iter370 teacher action #1 (HIGH priority) did not land in time for iter370 Q1. This continues to drag BC down ~1.5 points on every federation probe.

---

## ITER371 TEACHER ACTIONS — PRIORITY-ORDERED

1. **CRITICAL (correctness regression)** — `resources/22`: explicit "ANALYZE must run on the source Postgres database, NOT in Trino" callout for the JDBC PostgreSQL connector, with the 3-step sequence (psql ANALYZE → Trino SHOW STATS verify → SET SESSION join_reordering_strategy). This is a directly testable regression from iter369 carry-forward.
2. **HIGH (correctness)** — `resources/22`: add a "multi-way join execution model" section covering left-deep join tree, CBO ordering, per-join distribution choice, intermediate-result sizing as the multi-table OOM root cause. The responder's lack of this section directly caused the −1.5 completeness deduction.
3. **HIGH (clarity, 14th iter)** — `resources/22`: inline glossary for CBO / BROADCAST / PARTITIONED / build side / probe side / dynamic filtering / left-deep join tree. Iter370 action #1 did not land.
4. **MEDIUM (correctness)** — `resources/22`: replace `Join[BROADCAST]` / `Join[PARTITIONED]` references with canonical `join (INNER, REPLICATED)` / `join (INNER, PARTITIONED)` + `Exchange[REPLICATE]` tokens.
5. **MEDIUM (completeness)** — `resources/22`: add `join_max_broadcast_table_size` (default ~100MB) note — even a 500K-row table can exceed the threshold if rows are wide.
6. **LOW (running average)** — Federation topic dropped to 4.4910/262, gap to 4.5 widened from 0.0051 to 0.0090. Iter371 federation probe must be 4.7+ to recover.

## ITER371 JUDGE PROBE TARGETS

1. **CRITICAL re-probe** — "I tried `ANALYZE postgresql.public.customers` in Trino and got an error. How do I get stats for the CBO?" — tests action #1 lands.
2. Multi-way join execution model — "4-way join: events ⨝ customers ⨝ products ⨝ regions, and the THIRD join always blows up. Why?" — tests action #2.
3. EXPLAIN-reading — "I ran EXPLAIN and see `join (INNER, REPLICATED)` — what does REPLICATED mean?" — tests action #4.
4. Carry-forward iter370 probe target #1 (collection-duration vs wait-timeout) still pending.
5. Carry-forward iter370 probe target #2 (`enable_dynamic_filtering` master kill switch) still pending.
6. Carry-forward CDC tier 5th angle (snapshot isolation under concurrent CDC writes) still pending iter365-370.

## Topic running average update

- **Trino federation**: 4.4949/261 → **4.4910/262** (still NEEDS WORK; gap to 4.5 widened from 0.0051 to 0.0090; iter370 Q1 was a clear per-question FAIL at 3.375 and the regression was on the same ANALYZE-direction gap iter370 teacher action #4 was supposed to fix)

## Sources verified

- [PostgreSQL connector — Trino 481 Documentation](https://trino.io/docs/current/connector/postgresql.html) — ANALYZE must run on source Postgres, not via Trino catalog
- [EXPLAIN — Trino 480 Documentation](https://trino.io/docs/current/sql/explain.html) — broadcast annotation is `join (INNER, REPLICATED)` not `Join[BROADCAST]`
- [Cost-based optimizations — Trino 481 Documentation](https://trino.io/docs/current/optimizer/cost-based-optimizations.html) — confirmed `join_reordering_strategy`, `join_distribution_type`, `join_max_broadcast_table_size` session properties
- [Table statistics — Trino 480 Documentation](https://trino.io/docs/current/optimizer/statistics.html) — CBO uses connector-reported statistics

---

## Iter 370 End-of-Iteration Summary

**Iteration average: 3.98 — FAIL** (Q1 3.375 FAIL Trino federation 15th-iter angle three-table-join OOM execution model; Q2 4.59 STRONG PASS Iceberg time-travel + retention)

### Per-question recap

- **Q1 (Trino federation, 3-table join OOM): 3.375 FAIL** — CRITICAL correctness regression on ANALYZE direction: responder told user to run `ANALYZE postgresql.public.customers` in Trino, but per trino.io PostgreSQL connector docs the JDBC connector reads pre-collected Postgres stats — ANALYZE must run directly on the source Postgres database (psql), not through Trino's catalog. SHOW STATS FOR postgresql.public.customers verifies in Trino afterward. MINOR: `Join[BROADCAST]` is not a real Trino EXPLAIN token — canonical annotations are `join (INNER, REPLICATED)` for broadcast and `join (INNER, PARTITIONED)` for hash-redistributed, with adjacent `Exchange[REPLICATE]` nodes. The conceptual core of multi-table join execution (left-deep join tree, CBO ordering, per-join distribution choice, intermediate-result sizing as the actual OOM root cause) was skipped entirely — the user explicitly asked "how does Trino execute a three-table join" and got fixes without the model. 14th-iteration glossary gap on CBO / BROADCAST / PARTITIONED / build side / probe side / dynamic filtering persists in resources/22.
- **Q2 (Iceberg time-travel + retention): 4.59 STRONG PASS** — Iceberg time-travel and retention coverage held up well; topic mature across multiple angles.

### Patterns across iter360-370

- **Iter360-370 trajectory**: 4.0625 → 4.000 → 4.1875 → 4.0625 → 4.00 → 4.25 → 3.8125 → 4.625 → 4.375 → 4.47 → **3.98 FAIL** — first FAIL since iter366 (3.8125), breaks the three-iteration PASS streak iter367+368+369 that had been the first sustained ≥4.3 run since iter364-365.
- **Iter370 Q1 regression on the same gap iter370 teacher action #4 was supposed to close**: iter369 Q1 completeness deduction flagged the CBO/ANALYZE prerequisite for correct build-side selection in resources/22 DF section — iter370 teacher action #4 was the directly testable fix, and the responder repeated the same ANALYZE-direction error in iter370 Q1. The teacher action did not land in time. This is a clear iteration-over-iteration carry-forward failure on the federation topic.
- **Federation topic running average DROPPED**: 4.4949/261 → **4.4910/262** — gap to 4.5 STRONG-PASS threshold WIDENED from 0.0051 to 0.0090. The two-iteration trend (iter369 Q1 4.4375 sub-threshold + iter370 Q1 3.375 deep-FAIL) confirms the federation topic has REGRESSED relative to iter367+368 STRONG-PASS streak.
- **A/B confirmation continues**: iter369 cleanest A/B signal (glossary expansion DURABLY lifts BC by ~0.75 on dependent questions) holds — iter370 Q1 BC 3.5 (glossary still absent for CBO/build/probe/PARTITIONED/BROADCAST/left-deep-tree terms) consistent with the iter369 baseline. The 14th-iter glossary gap continues to drag every federation probe by ~1.5 points.
- **Std-dev iter370 1.21** — widest pass-band in iter360-370 window (vs iter369 std-dev 0.045 tightest). Q1/Q2 polarization driven by iter370 Q1's deep FAIL plus iter370 Q2's solid STRONG PASS on Iceberg time-travel.

### ITER371 TEACHER ACTIONS — PRIORITY-ORDERED (carried into next iteration)

1. **CRITICAL (correctness regression, 2nd-iter carry-forward)** — resources/22: explicit "ANALYZE must run on the source Postgres database, NOT in Trino" callout with 3-step sequence (psql ANALYZE on Postgres → Trino SHOW STATS verify → SET SESSION join_reordering_strategy). Single highest-leverage action.
2. **HIGH (correctness)** — resources/22: multi-way join execution model section (left-deep join tree, CBO ordering, per-join distribution choice, intermediate-result sizing as multi-table OOM root cause).
3. **HIGH (clarity, 15th iter)** — resources/22: inline glossary for CBO / BROADCAST / PARTITIONED / build side / probe side / dynamic filtering / left-deep join tree.
4. **MEDIUM (correctness)** — resources/22: replace `Join[BROADCAST]` / `Join[PARTITIONED]` references with canonical `join (INNER, REPLICATED)` / `join (INNER, PARTITIONED)` + `Exchange[REPLICATE]` tokens.
5. **MEDIUM (completeness)** — resources/22: `join_max_broadcast_table_size` (default ~100MB) note.
6. **LOW (running average recovery)** — Federation topic dropped to 4.4910/262, gap to 4.5 widened to 0.0090. Iter371 federation probe must be 4.7+ to recover.

### ITER371 JUDGE PROBE TARGETS (carried into next iteration)

1. **CRITICAL re-probe** — "I tried `ANALYZE postgresql.public.customers` in Trino and got an error. How do I get stats for the CBO?" — tests action #1 lands.
2. Multi-way join execution model — "4-way join: events ⨝ customers ⨝ products ⨝ regions, and the THIRD join always blows up. Why?" — tests action #2.
3. EXPLAIN-reading — "I ran EXPLAIN and see `join (INNER, REPLICATED)` — what does REPLICATED mean?" — tests action #4.
4. Carry-forward iter370 probe target #1 (collection-duration vs wait-timeout) still pending.
5. Carry-forward iter370 probe target #2 (`enable_dynamic_filtering` master kill switch) still pending.
6. Carry-forward CDC tier 5th angle (snapshot isolation under concurrent CDC writes) still pending iter365-370.

### Training state

- `passed: true` remains (extended-phase quality push through 2026-05-30 12:00 CST deadline — final day of training loop).
- Iter370 average 3.98 FAIL does not flip pass state but confirms federation topic regression needs immediate resource intervention in iter371.
