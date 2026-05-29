# Iter 372 Q1 — Judge Feedback

## Question

"My SELECT COUNT(DISTINCT user_id) across 2B rows takes 5 minutes. What does approx_distinct do, how much faster is it, and when is it safe to use?"

**Topic**: SQL query best practices for OLAP — approximate aggregation (HyperLogLog / approx_distinct)

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | All factual claims verified against Trino official docs. HyperLogLog is correct algorithm. 2.3% standard error is the documented σ. The 68% within ±2.3% / 95% within ±4.6% framing is the correct interpretation of "approximately normal error distribution" from Trino docs. "Few KB sketch" matches Trino's ~8 KB dense layout. 10–50x speedup band is realistic for 2B-row exact COUNT DISTINCT vs HLL. Multi-shuffle root cause is correct (matches iter193 prior correction — NOT the "all to one coordinator" misconception). |
| Beginner clarity | 4.5 | "Sketch", "HyperLogLog", "standard error" all defined in context. Translating 2.3% σ into 68%/95% confidence buckets is the right move for engineers who do not think in standard deviations. Safe/unsafe split is concrete and scannable. Minor: HyperLogLog itself could get a one-line gloss ("probabilistic data structure for cardinality estimation") on first mention. |
| Practical applicability | 5.0 | Engineer knows exactly what to do next: (a) safe-use checklist with concrete categories (internal dashboards, >10M cohorts, trend charts) vs unsafe (customer-facing, billing/seat counts, <1K cohorts); (b) validation recipe (compare exact vs approx_distinct across 5–10 partitions); (c) production pattern (pre-built daily HyperLogLog sketch table for repeated DAU/WAU). All three are directly executable in the on-prem Trino 467 + Iceberg + MinIO stack. |
| Completeness | 4.5 | All three sub-questions answered (what / how fast / when safe). Validation recipe and production sketch pattern are bonus. Gaps: (a) did not surface `approx_distinct(x, e)` accuracy parameter (e in [0.0040625, 0.26]) for tuning tighter error at higher memory cost; (b) `approx_set()` / `merge()` HyperLogLog building-block functions mentioned conceptually as "pre-built daily sketch" but not by name — engineer needs those function names to actually build the production pattern; (c) sparse-vs-dense crossover at 256 distinct values (where error is 0 below 256) is a nice-to-mention edge case for small cohort warnings. |

**Average: (5.0 + 4.5 + 5.0 + 4.5) / 4 = 4.75 — STRONG PASS**

(Above 4.0 per-question bar; above 4.5 strong-pass bar.)

---

## WebSearch verification

1. **HyperLogLog IS the algorithm used by `approx_distinct` in Trino** — CONFIRMED via [HyperLogLog functions — Trino 479 Documentation](https://trino.io/docs/current/functions/hyperloglog.html) and [Aggregate functions — Trino 481 Documentation](https://trino.io/docs/current/functions/aggregate.html). Trino implements HyperLogLog data sketches as 32-bit buckets, sparse layout up to 256 distinct values (exact), then ~8 KB dense layout.

2. **2.3% IS the documented standard error for `approx_distinct`** — CONFIRMED via Trino Aggregate functions docs: "approx_distinct(x): Returns the approximate number of distinct input values. ... This function should produce a standard error of 2.3%, which is the standard deviation of the (approximately normal) error distribution over all possible sets. It does not guarantee an upper bound on the error for any specific input set." Trino also offers `approx_distinct(x, e)` where e is in [0.0040625, 0.26000] for custom accuracy.

Both core technical claims fully verified against official Trino docs.

---

## Topic running average

- **SQL query best practices for OLAP**: 4.652/16 → **4.658/17** (PASSED — improved, stable above 4.5 strong-pass bar)

This was the **17th question** testing this topic. Topic is mature, durably passing across multiple distinct angles: partition pruning, SELECT *, approximate functions (approx_distinct + approx_percentile), EXPLAIN verification, type-safe predicates, pushdown-breaking patterns, HyperLogLog rolling-window varbinary cast, COUNT(DISTINCT) cost root cause.

---

## Gaps (deductions from 5.0)

- **Beginner clarity (−0.5)**: HyperLogLog first mention lacks a one-line gloss ("probabilistic data structure for cardinality estimation that trades a few KB of memory for a 2.3% standard error vs exact counting"). Engineers without OLAP background will recognize "sketch" but may not immediately link HyperLogLog to the broader family of probabilistic data structures.
- **Completeness (−0.5)**:
  - (a) `approx_distinct(x, e)` accuracy parameter not mentioned — engineers can tune the error/memory tradeoff (smaller e = tighter error but more memory; e must be in [0.0040625, 0.26]). This is the answer to "what if 2.3% is too loose for my use case?"
  - (b) The production sketch pattern is described conceptually but the function names `approx_set()` (build a HLL sketch) and `merge()` (combine sketches across partitions/time windows) are not surfaced. Engineer cannot actually implement the "pre-built daily HyperLogLog sketch table" pattern without those function names plus the `CAST(... AS varbinary)` storage gotcha (retested at iter192 — that varbinary cast pattern should be linked here on the first question, not the second).
  - (c) Sparse/dense layout crossover at 256 distinct values — for tiny cohorts (<256), `approx_distinct` returns the exact count with 0 error. This means the "tiny cohorts (<1K)" unsafe band is overly conservative; the real cliff where error kicks in is <256.

---

## Iter 373 teacher actions (priority-ordered)

1. **MEDIUM (completeness, recurring approximate-aggregation theme)** — In `resources/07` or `resources/23` (whichever holds the approx_distinct treatment), ensure the section on `approx_distinct` explicitly names:
   - `approx_distinct(x, e)` with e range [0.0040625, 0.26] and a worked tradeoff example
   - `approx_set()` + `merge()` for the rolling-sketch production pattern, with the `CAST(... AS varbinary)` storage and `CAST(col AS HyperLogLog)` read-side double cast (already documented per iter192, but cross-link from the `approx_distinct` section so engineers find it on the first question, not the second)
   - Sparse-vs-dense crossover at 256 (zero error below 256 because sparse layout is exact)

2. **LOW (beginner clarity)** — One-line gloss for "HyperLogLog" on first mention: "a probabilistic data structure that estimates how many distinct values exist in a stream using a fixed-size memory footprint (a few KB), independent of the actual distinct-value count."

3. **CARRY-FORWARD from iter372** — Federation glossary expansion in `resources/22` (CBO, BROADCAST, PARTITIONED, build-side, probe-side, left-deep join tree, join_distribution_type, join_reordering_strategy, dynamic filtering) — 15th-iter-flagged glossary drag. Not tested this iter Q1 but still pending for next federation probe.

4. **CARRY-FORWARD from iter370/371** — `enable_dynamic_filtering` master kill switch + multi-way left-deep join tree execution model + CDC snapshot isolation under concurrent writes.

---

## Iter 373 judge probe targets

1. **Approximate aggregation accuracy tuning**: "approx_distinct gave me 2.3% error but my product manager wants <1%. Can I tune it, and what's the tradeoff?" — tests iter373 action #1 (the `approx_distinct(x, e)` accuracy parameter).
2. **Production rolling sketch pattern**: "I want to build a daily HyperLogLog sketch table so my DAU/WAU/MAU dashboards are fast. What functions do I use, what data type do I store, and how do I merge across days?" — tests iter373 action #1 (`approx_set` + `merge` + varbinary cast cross-link).
3. **Carry-forward**: federation glossary, federation backup knobs, federation replica caveat, `enable_dynamic_filtering` kill switch, multi-way left-deep join tree.

---

## Pattern observations

- (a) Iter372 Q1 is a clean 4.75 STRONG PASS on the approximate-aggregation angle of SQL best practices — topic durably above 4.5 across 17 questions covering 8+ distinct sub-topics. This is the most mature topic in the rubric outside of Postgres-to-Iceberg ingestion.
- (b) The 2.3% standard error correction (iter193 resource fix from "~2% error" to "2.3% standard error per Trino docs") has fully propagated — responder pulls the correct value AND the correct framing (σ not hard ceiling, normal distribution interpretation) without prompting.
- (c) The multi-shuffle root cause correction (iter195 resource fix from "all user_ids shuffle to single coordinator" to "multi-shuffle overhead + per-group memory") has also fully propagated — responder names multi-shuffle, not centralization.
- (d) Both critical technical corrections from past iterations on this exact topic are now durably correct on the 17th probe — confirms `resources/07` and `resources/23` are stable for the approximate-aggregation theme.
- (e) Remaining gap is minor surface area (accuracy parameter + approx_set/merge function names + 256 sparse cliff) — not correctness regressions, just completeness polish.

---

## Iter 372 End-of-Iteration Summary

### Iteration results

| Question | Topic | Score | Result |
|---|---|---|---|
| Q1 | SQL best practices — `approx_distinct` vs COUNT DISTINCT (HyperLogLog) | 4.75 | STRONG PASS |
| Q2 | Iceberg schema evolution — INT→BIGINT type widening | 4.75 | STRONG PASS |
| **Iteration average** | | **4.75** | **STRONG PASS** |

Per-dimension iteration averages (Q1 5.0/4.5/5.0/4.5, Q2 5.0/4.5/5.0/4.5): TA 5.0, BC 4.5, PA 5.0, Comp 4.5. Uniform 4.5/5.0 split across BOTH questions — std-dev 0.0 between Q1 and Q2 (zero polarization, both probes scored identical per-dimension). Two distinct topics tested on same iteration both landed identical 4.75 STRONG PASS — confirms resource quality flat across SQL approximate-aggregation AND Iceberg schema-evolution clusters.

### Topic running averages (post-iter372)

- **SQL query best practices for OLAP**: 4.652/16 → **4.658/17** (PASSED — 17th probe, improved, durably above 4.5 strong-pass bar across 8+ sub-angles: partition pruning, SELECT *, approx_distinct, approx_percentile, EXPLAIN verification, type-safe predicates, pushdown-breaking patterns, HyperLogLog rolling-window varbinary cast, COUNT(DISTINCT) cost root cause)
- **Iceberg schema evolution**: prior-running-avg → **lifted by Q2 4.75** (durability extended on INT→BIGINT type-widening angle, on top of prior column-add / column-rename through CDC / column-drop angles)

### Trajectory iter360-372

4.0625 → 4.000 → 4.1875 → 4.0625 → 4.00 → 4.25 → 3.8125 → 4.625 → 4.375 → 4.47 → 3.98 FAIL → 4.5625 PASS → **4.75 STRONG PASS** — iter372 is the highest iteration average since iter367 4.625, extends iter371 recovery into a 2-iter streak above 4.5, AND iter372 is the highest std-dev=0 cross-topic uniform pass since iter365 — proves resource quality is stable across BOTH a mature topic (SQL best practices, 17th probe) AND a still-maturing topic (Iceberg schema evolution).

### Gap analysis (deductions from 5.0)

Both Q1 and Q2 deducted 0.5 on BC and 0.5 on Completeness — identical pattern across both topics:

- **BC −0.5 both questions**: jargon (HyperLogLog in Q1, "type promotion" / "format-version 2" / "row-id reuse" in Q2) used without inline one-line gloss on first mention. Same drag pattern as iter371 federation glossary BC ceiling. Suggests broader resource pattern: technical terms are correctly USED in resources but not glossed on first occurrence.
- **Completeness −0.5 both questions**: known sub-features omitted — Q1 missed `approx_distinct(x, e)` accuracy parameter + `approx_set()`/`merge()` function names + sparse-vs-dense 256 cliff; Q2 missed (whatever Iceberg schema-evolution edge case was flagged — see feedback for Q2 file if separate).

### Iter 373 teacher actions (priority-ordered)

1. **HIGH (recurring BC drag, 2-iter pattern)** — Inline one-line glosses on first mention for jargon across ALL resource files, starting with the most-tested topics: HyperLogLog gloss in `resources/07`+`resources/23`; CBO/BROADCAST/PARTITIONED/build-side/probe-side/left-deep-join-tree glossary in `resources/22`; "type promotion" + "format-version 2" + "row-id reuse" glosses in Iceberg schema-evolution section.

2. **MEDIUM (Q1 completeness)** — In `resources/07` or `resources/23`, surface on the `approx_distinct` section: (a) `approx_distinct(x, e)` accuracy parameter with e in [0.0040625, 0.26] and worked tradeoff example; (b) `approx_set()` + `merge()` HyperLogLog building-block names with `CAST(... AS varbinary)` storage and `CAST(col AS HyperLogLog)` read-side double cast cross-linked from approx_distinct section (not just from the rolling-sketch section); (c) sparse-vs-dense crossover at 256 distinct values (zero error below 256).

3. **CARRY-FORWARD from iter371-372** — Federation glossary expansion in `resources/22` (CBO, BROADCAST, PARTITIONED, build-side, probe-side, left-deep join tree, join_distribution_type, join_reordering_strategy, dynamic filtering) — 15th-iter-flagged glossary drag — still pending, but iter372 did not probe federation so drag did not manifest this iteration. Will re-emerge on next federation probe.

4. **CARRY-FORWARD from iter370-372** — `enable_dynamic_filtering` master kill switch + multi-way left-deep join tree execution model + CDC snapshot isolation under concurrent writes + federation replica WAL caveat.

### Pattern observations

- (a) Iter372 is the strongest iteration since iter367 4.625 — std-dev 0 between Q1 and Q2 (both 4.75) confirms resource quality is uniform across two distinct mature topic clusters.
- (b) 2-iter streak above 4.5 (iter371 4.5625 + iter372 4.75) recovers from iter370 3.98 FAIL — iter370 was a singular regression, not a trend.
- (c) Identical per-dimension deduction pattern (TA 5.0, BC 4.5, PA 5.0, Comp 4.5) on BOTH Q1 and Q2 strongly suggests the remaining gap is a STRUCTURAL resource pattern (jargon-without-gloss on first mention + omitted sub-feature names), not a topic-specific knowledge gap. This is fixable with a single editorial pass across resource files focused on first-mention glosses.
- (d) SQL best practices topic at 17 probes 4.658/17 average is now the most mature topic in the rubric — durably above 4.5 across 8+ distinct sub-angles.
- (e) Iceberg schema-evolution topic durability extended via Q2 4.75 on INT→BIGINT angle — joins SQL best practices in the durable-top-tier cluster.
- (f) Training-loop final day. Iter372 likely last or near-last iteration of extended-phase quality push. Loop continues passed:true with strong end-state trajectory.

