# Iter 154 Q1 — Judge Report

**Question topic**: Trino join OOM — `BROADCAST` vs `PARTITIONED` join distribution, memory math, spill-to-disk fallback.

**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter154-q1.md`

---

## Scores

| Dimension | Score | Rationale |
|---|---|---|
| **Technical accuracy** (2x) | 5 | All major claims verified against Trino official docs. Session property name and syntax correct. PARTITIONED vs BROADCAST mechanics correct. Spill property names correct. EXPLAIN ANALYZE fields verified. One minor caveat (see below) but no factual errors. |
| **Clarity** (1x) | 5 | Excellent structure: opens with the user's misconception ("shouldn't Trino be smart enough"), then "what's actually happening in memory" before solution. Numbered steps, two side-by-side memory-math bullets, runnable SQL, and a clear escalation ladder. No unexplained jargon — "hash table", "shuffle", "build side", "probe side" are either used in plain context or implied by an analogy. |
| **Practical usefulness** (1x) | 5 | One-liner fix at the top (`SET SESSION join_distribution_type = 'BROADCAST'`), an actual runnable query the engineer can paste in, a safety check ("when BROADCAST is safe" with the 4 GB rule), three concrete fallback levers in priority order, and an EXPLAIN ANALYZE recipe with a decision rule based on `Scheduled:` vs `CPU:`. The engineer knows exactly what to do next. |
| **Completeness** (1x) | 5 | Addresses all three sub-questions: (a) why a tiny-table join OOMs ("each worker builds a partial hash table after the shuffle"), (b) the hint to give Trino (`BROADCAST` with full syntax), (c) what's happening in memory (PARTITIONED memory math vs BROADCAST memory math). Also covers spill-to-disk as the last-resort safety net and partition-filter restructuring as the lighter-weight fix — both of which are the natural follow-up questions. |

**Weighted average** = (5×2 + 5 + 5 + 5) / 5 = **5.00 / 5**

**Result**: **PASS** (≥ 4.5)

---

## What was verified correct (with sources)

1. **`SET SESSION join_distribution_type = 'BROADCAST'` syntax** — verified. The session property exists in Trino, replaces the deprecated `distributed_joins` config, and accepts `BROADCAST`, `PARTITIONED`, and `AUTOMATIC`. The answer's `SET SESSION join_distribution_type = 'BROADCAST'` is the exact correct syntax. ([General properties — Trino docs](https://trino.io/docs/current/admin/properties-general.html), [Cost-based optimizations — Trino docs](https://trino.io/docs/current/optimizer/cost-based-optimizations.html))

2. **PARTITIONED vs BROADCAST memory behavior** — verified. PARTITIONED hashes both sides on the join key and shuffles both; BROADCAST sends a full copy of the build (smaller) side to every worker so the probe side can be joined locally without a shuffle. The answer's memory math ("PARTITIONED: hash table for slice of 500M + slice of 50K; BROADCAST: hash table for full 50K + streamed events slice") matches the docs. ([Cost-based optimizations — Trino docs](https://trino.io/docs/current/optimizer/cost-based-optimizations.html))

3. **Spill property names** — verified. `spill-enabled`, `spiller-spill-path`, `spill-compression-codec`, `max-spill-per-node`, and `query-max-spill-per-node` are all correct property names in the official Trino spilling docs. ([Spilling properties — Trino docs](https://trino.io/docs/current/admin/properties-spilling.html), [Spill to disk — Trino docs](https://trino.io/docs/current/admin/spill.html))

4. **EXPLAIN ANALYZE `Scheduled:` and `CPU:` fields** — verified. Both fields appear in per-operator output of `EXPLAIN ANALYZE`. The answer's heuristic ("Scheduled >> CPU → I/O-bound on shuffle") is a reasonable and commonly cited rule. ([EXPLAIN ANALYZE — Trino docs](https://trino.io/docs/current/sql/explain-analyze.html))

5. **Spill-compression `LZ4` value** — verified. `spill-compression-codec` accepts `NONE`, `LZ4`, `ZSTD`. The answer's `LZ4` example is valid. ([Spilling properties — Trino docs](https://trino.io/docs/current/admin/properties-spilling.html))

---

## Minor caveats (do not affect score)

- **`query.max-memory-per-node = 4GB` default**: The answer says "Trino's default is `query.max-memory-per-node = 4GB` (check your config)." In current Trino docs, this property defaults to **30% of the JVM max heap on the node**, not a fixed 4 GB. The answer hedges with "(check your config)" and uses 4 GB only as an illustrative example, not a load-bearing claim — so this is acceptable. Teacher could tighten the resource to say "typically a few GB per worker — depends on JVM heap size (default 30% of max heap)" rather than asserting a fixed number. **Severity: LOW.** ([Resource management properties — Trino docs](https://trino.io/docs/current/admin/properties-resource-management.html))

- **AUTOMATIC option not mentioned**: Trino's `join_distribution_type` has three values: `BROADCAST`, `PARTITIONED`, `AUTOMATIC`. The answer only contrasts `BROADCAST` vs `PARTITIONED`. `AUTOMATIC` lets the cost-based optimizer pick — which is arguably what the user *wished* Trino was doing by default. Mentioning it would round out the answer ("the planner CAN pick automatically if `AUTOMATIC` is set and CBO has stats, but on this stack the default is `AUTOMATIC` in recent Trino and the issue is usually missing stats from `ANALYZE TABLE`"). **Severity: LOW** — does not change the actionable fix.

- **`query.max-spill-per-node` definition slightly different in docs**: The resource calls this "per-query spill limit on one node." Official docs phrase it as the max per-query spill space allowed on a single node — same meaning, no error.

---

## Errors or gaps found

None that materially affect the answer's correctness or usefulness.

---

## Resource fix recommendations

- **LOW**: In `resources/18-query-performance-regression.md`, replace the assertion "Trino's default is `query.max-memory-per-node = 4GB`" with the more accurate "defaults to 30% of the JVM max heap on the worker — check your `etc/jvm.config` and `etc/config.properties` for the actual value." This is a minor precision improvement, not a blocker.
- **LOW**: Add a one-sentence mention of `AUTOMATIC` as a third value of `join_distribution_type`, noting that it requires table statistics from `ANALYZE TABLE` to make a good decision — this preempts the natural "why didn't Trino pick BROADCAST itself?" follow-up.

---

## Rubric update

Topic touched: **Query performance regression diagnosis: oncall workflow for slow queries — concurrency, partition skew, data model, file layout** (already PASSED at avg 5.0 over 2 questions). New running avg with this 5.00 result: 5.0 over 3 questions. Status remains PASSED.
