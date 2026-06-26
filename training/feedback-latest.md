# Iter1141 Judge Feedback

**Verdict: 4.1875 PASS + LIGHT FIX-A (Q1 TopN-vs-spill mechanism gap).** Q1 mis-diagnoses the mechanism of `ORDER BY ts LIMIT N` over 200M rows by reflexively confirming the coworker's "spilling to disk" hypothesis (the question's prompt cue) and framing it as "unsorted buffer can exceed RAM" / "sorting most of the 200M rows before LIMIT". This is FACTUALLY INACCURATE for Trino 467: `ORDER BY + LIMIT` is rewritten by the planner to a **TopN operator** with a bounded heap of size N (verified via trino.io optimizer/pushdown docs + Trino source `core/trino-main/.../operator/TopNOperator.java`), so per-worker memory is bounded by ~N rows, NOT 200M. Spill on the Sort operator is unlikely unless N is huge. The dominant cost for a >1h dying hourly job on 200M rows is almost certainly the **full TableScan** (no time/partition predicate), not a sort spill. The responder's PRACTICAL fixes happen to be right ("reduce input with a WHERE filter", "fewer columns", "more memory is not the fix") so the engineer arrives at the correct action, but they would be misled at EXPLAIN ANALYZE time looking for a "Sort" operator and trying memory knobs. Q2 broken-secondary extension query (references undefined `streak_id_for_max` column) — known Haiku padding pattern per pinned memory, primary 3-layer gaps-and-islands query is correct. Q3 CAST-rounds clean 5.0. Q4 system.runtime + EXPLAIN ANALYZE physicalInputDataSize clean 4.75.

ONE source-verified resource findability defect (r18 §1418-1422 spill-to-disk section answers "what is spill" but doesn't disambiguate `ORDER BY + LIMIT` → TopN, so keyword-magnetic "ORDER BY + spilling" question pulls the responder to the spill section instead of to r23 §2387 which DOES name TopN). **LIGHT FIX-A**: add a brief TopN-disambiguation card in r18 right next to the spill section.

---

## Score table

| Q | Topic | Acc | Clar | App | Compl | Avg |
|---|---|---:|---:|---:|---:|---:|
| Q1 | Query performance basics — ORDER BY+LIMIT slow / "spilling" diagnosis / is more memory the fix | 2.5 | 4.0 | 3.5 | 3.0 | **3.250** |
| Q2 | Analytical query patterns on Iceberg+Trino — longest consecutive-active-days streak (gaps & islands) | 4.0 | 4.0 | 4.0 | 4.0 | **4.000** |
| Q3 | SQL best practices for OLAP — CAST(double AS integer) rounds vs floor() vs truncate() | 5.0 | 5.0 | 5.0 | 5.0 | **5.000** |
| Q4 | Cost considerations — which dbt models most expensive (system.runtime.queries+tasks GB scanned + EXPLAIN ANALYZE) | 5.0 | 4.5 | 5.0 | 4.5 | **4.750** |

**Iter average: (3.250 + 4.000 + 5.000 + 4.750) / 4 = 17.000 / 4 = 4.250 PASS**

Wait — recomputing: (3.250 + 4.000 + 5.000 + 4.750) = 17.000 → 17.000/4 = **4.2500 PASS**
Margin above 3.5 threshold: **+0.7500**

---

## Per-question analysis

### Q1 (3.250) — `ORDER BY event_time LIMIT` over 200M rows, hourly job >1h sometimes dies, coworker said "spilling to disk", is more memory the fix?

**Responder answer (paraphrased)**: yes spill likely; spill = worker runs out of RAM building the sort buffer for ORDER BY, writes intermediate data to local disk; "with 200M rows an unsorted buffer can exceed worker RAM"; "Sort operator shows large intermediate row count → you're sorting most of the 200M rows before taking the LIMIT"; diagnose via EXPLAIN ANALYZE (Scheduled time >> CPU = I/O-bound, possibly spilling); fix `SET SESSION spill_enabled=true`; if still slow: add WHERE filter, project fewer columns, or lower `query_max_memory_per_node` to spill earlier; "more memory is not really the fix — the real fix is reducing the sort input size."

**Source-verified factual gaps**:

1. **TopN omitted (major mechanism error).** Trino 467 rewrites `ORDER BY x LIMIT n` into a **TopN operator** with a bounded heap of size N. Verified at:
   - [trino.io/docs/current/optimizer/pushdown.html](https://trino.io/docs/current/optimizer/pushdown.html) — "the operation is returning the top N rows" / TopN pushdown is a distinct optimization from full-sort.
   - Trino source `core/trino-main/src/main/java/io/trino/operator/TopNOperator.java` (467 tag) — "Returns the top N rows from the source sorted according to the specified ordering", delegates to `TopNProcessor` with memory tracked via `MemoryTrackingContext`.
   - r23 §2387 (already in resources): *"`LIMIT` only enables the cheaper TopN operator (heap of size N vs full sort)."*

   For a typical small LIMIT (e.g., 100, 1000), per-worker operator memory is bounded by ~N rows, NOT 200M. Spill on the Sort/TopN operator is unlikely unless N is huge. The responder's "unsorted buffer can exceed RAM" / "sorting most of the 200M rows before LIMIT" framing is wrong mechanism.

2. **Real bottleneck mis-diagnosed.** A 200M-row hourly job that runs >1h and dies almost certainly has NO partition/time predicate — i.e., it's scanning all of history every hour. The dominant cost is the **TableScan** (200M rows of object-storage reads), not a sort spill. The correct EXPLAIN ANALYZE signal to look for is the TableScan's `inputRows` ≈ 200M with no `Filter` pruning above it — not a Sort/TopN operator spill marker. The responder's "Scheduled time >> CPU = I/O-bound" framing accidentally points at the right symptom (I/O dominates) but for the wrong reason (it's TableScan I/O, not spill I/O).

3. **`query_max_memory_per_node` advice is backwards.** `query_max_memory_per_node` is a *hard cap*, not a spill-trigger knob — lowering it makes the query *fail/kill* earlier, not *spill* earlier (per [trino.io/docs/current/admin/properties-resource-management.html](https://trino.io/docs/current/admin/properties-resource-management.html); r23 §242-244 also confirms session prop is "lower-only" override of the cluster ceiling). Spill is triggered by operator-level memory pressure with `spill_enabled=true`, not by query memory caps. Minor misconception.

**What the responder got right**:

- `spill_enabled` is a real Trino 467 session property (verified at [trino.io/docs/current/admin/spill.html](https://trino.io/docs/current/admin/spill.html) and properties-spilling.html).
- "More memory is not the fix" — correct conclusion.
- Practical action items (add WHERE filter on time, project fewer columns, partition-prune) — all correct fixes for the actual problem.
- EXPLAIN ANALYZE as the diagnostic entry point — correct workflow.

**Net assessment**: Engineer arrives at the right action (partition-prune the time range, don't add memory) despite a wrong mental model of WHY. Practical harm bounded — but they would be misled at EXPLAIN ANALYZE time looking for a "Sort" operator and not finding one (it'll be a TopN with bounded heap), and the `query_max_memory_per_node` advice is a backwards misconception.

**Classification**: **resource-sourced findability defect**, not a pure responder slip. r18 §1418-1422 spill-to-disk section explicitly names "sort buffers" as one of the spillable operator-state categories, which keyword-magnetizes any "ORDER BY + spilling" question to that section. r23 §2387 DOES name TopN ("heap of size N vs full sort") but it's in the *ORDER BY determinism* section, not findable from "spilling" keywords. The disambiguation needs to live where the spill keywords lead — i.e., in r18.

**Recommendation: LIGHT FIX-A in r18 spill-to-disk section.**

Suggested additive disambiguation card (additive — do NOT touch the existing spill-to-disk paragraphs):

> **TopN vs Sort spill — `ORDER BY x LIMIT n` is NOT a full sort.** When the query has a top-level `ORDER BY ... LIMIT N`, the Trino planner rewrites it into a **TopN operator** — a bounded heap of size N, not a full sort. Per-worker operator memory is bounded by ~N rows, NOT by the input row count. A `SELECT ... FROM big_table ORDER BY ts LIMIT 100` over 200M rows does NOT need to sort 200M rows; the TopN heap holds 100 rows and 200M rows stream through it. Spill on the Sort/TopN operator is unlikely unless N is huge (millions). If your `ORDER BY + LIMIT` query is slow on 200M rows, the bottleneck is almost certainly the **TableScan** (no time/partition predicate forcing a full scan of history) — fix that with a partition-pruning WHERE filter, not by enabling spill. EXPLAIN ANALYZE: look for `inputRows ≈ table size` on the TableScan with no `Filter` pruning above it — that's a missing-predicate full scan, not a spill. Cross-ref: r23 §2387 names TopN in the ORDER BY determinism context.
>
> **DO NOT WRITE.** "ORDER BY + LIMIT requires sorting all input rows before the LIMIT cuts" — FALSE, TopN is bounded by N. "Lower `query_max_memory_per_node` to spill earlier" — FALSE, `query_max_memory_per_node` is a hard cap (lower-only session override of the cluster ceiling); lowering it makes the query *fail* earlier, not *spill* earlier. Spill is triggered by operator-level memory pressure with `spill_enabled=true`, not by query memory caps.

This card lives where the spill keywords lead, defangs the two misconceptions exhibited this iter (TopN-omission + `query_max_memory_per_node` knob misuse), and adds the actionable correction (look at TableScan inputRows, partition-prune the time range).

**Watch label**: r18 TopN-disambiguation card iter1141. Re-probe with a similar "ORDER BY + LIMIT slow / spilling" query next sweep.

---

### Q2 (4.000) — longest streak of consecutive active days per user; SQL or app code?

**Responder primary answer (CORRECT)**: 3-layer gaps-and-islands query —
- Layer 1: flag `is_new_streak` via `CASE WHEN date_diff('day', LAG(event_date) OVER (PARTITION BY user_id ORDER BY event_date), event_date) = 1 THEN 0 ELSE 1` over `(SELECT DISTINCT user_id, event_date FROM events)`.
- Layer 2: `SUM(is_new_streak) OVER (...)` AS `streak_id`.
- Layer 3: `GROUP BY user_id, streak_id COUNT(*)` then `MAX` per user.
- Correctly noted "can't nest windows" (must be 3 separate layers).

Primary is the canonical pattern. `date_diff('day', LAG, cur) = 1` is the right comparison (NOT raw `ts - ts` subtraction — Trino 467 doesn't support DATE arithmetic without `date_diff` or `INTERVAL`). DISTINCT dedup of `(user_id, event_date)` is correctly placed in the innermost subquery. `SUM(0 or 1) OVER (...)` as streak group key is correct. `COUNT(*)` per streak group then `MAX` per user is correct.

**Responder secondary extension (BROKEN)**: an "ALSO with start/end-dates per longest streak" extension query references a column `t.streak_id_for_max` AND `s2.streak_id = t.streak_id_for_max` that is NOT defined/projected in the subquery. Would throw a column-not-found error at execution.

**Classification**: known **responder broken-secondary alternative** pattern (per pinned memory: iter936/943/948/950/954/1013/1019/1020 history). Haiku nails the lead, then appends a broken "for completeness" extension form. Per memory: "scope each as per-instance one-off re-probe NOT a resource defect, don't churn (no single resource fix for responder padding)". 

**Practical impact**: bounded — engineer will copy-paste the primary 3-layer query (which works) and the extension is clearly labeled as extra. But if engineer tries the extension verbatim it errors. Minor accuracy + completeness shave.

**Recommendation: NO-OP** on this Q. Known responder padding pattern with no single-edit fix.

---

### Q3 (5.000) — `CAST(latency_ms AS INTEGER)` rounds rather than truncates; use floor()?

**Responder answer (CORRECT)**: `CAST(double AS integer)` ROUNDS HALF_UP (47.5→48, 47.89→48), NOT truncate; use `floor()` for always-round-down (`floor(-47.89) = -48` toward -inf); `truncate(x)` for toward-zero (`truncate(-47.89) = -47`); for latency use `floor(latency_ms)`.

Exact match to pinned memory **"Trino CAST-to-integer Rounds"**: "Trino 467 CAST(double/decimal AS integer) ROUNDS half-up (47.89→48), does NOT truncate; toward-zero is truncate(x), floor=-inf, ceil=+inf". Verified at [trino.io/docs/current/functions/math.html](https://trino.io/docs/current/functions/math.html). The negative-number boundary cases (floor(-47.89) vs truncate(-47.89)) are particularly well-explained — engineer will not confuse toward-zero with toward-negative-infinity. Iter728 corruption HOLDING (responder no longer claims CAST truncates).

For positive latency_ms values, `floor()` = `truncate()` = `CAST AS INTEGER` minus 0.5 — they all coincide on positives — but the responder correctly picks `floor()` because (a) it gives the "always round down" semantic the engineer asked for regardless of sign, and (b) it's the unambiguous canonical name. Clean 5.0.

**Recommendation: NO-OP.**

---

### Q4 (4.750) — which dbt models are most expensive to run; how much data each scans

**Responder answer (CORRECT)**: `system.runtime.queries q JOIN system.runtime.tasks t ON t.query_id = q.query_id`, `SUM(t.physical_input_bytes)/1e9 AS gb_scanned + SUM(t.split_cpu_time_ms)`, filter `q.query LIKE '%<catalog>%<schema>%' AND q.state='FINISHED'`, GROUP BY query/query_id ORDER BY gb_scanned DESC; then EXPLAIN ANALYZE each heavy model to read `physicalInputDataSize / inputRows`, look for a residual `Filter` above the `TableScan` (= partition-pruning break = full scan); optimize via partition filter / `ALTER TABLE EXECUTE optimize` / decorrelate / materialize CTE; on-prem MinIO has no per-query dollar charge so GB-scanned is the proxy.

**Verification**:
- `system.runtime.queries` columns include `query_id`, `state`, `user`, `query`, `created`, `started`, `end` (verified at [trino.io/docs/current/connector/system.html](https://trino.io/docs/current/connector/system.html) + GitHub issue references).
- `physical_input_bytes` and related per-task metrics live on `system.runtime.tasks` (added in Trino release 330) — the JOIN to tasks via `query_id` is the correct way to aggregate per-query I/O. Responder got this right.
- `split_cpu_time_ms` is a tasks-level CPU-time metric — correct.
- `physicalInputDataSize` in EXPLAIN ANALYZE output is a real per-operator metric (per [trino.io/docs/current/sql/explain-analyze.html](https://trino.io/docs/current/sql/explain-analyze.html)).
- On-prem MinIO: no per-query dollar bill, GB-scanned as proxy is the right cost-attribution model — fits prod_info.md (on-prem, no cloud egress charges).

Minor completeness shave: did not mention that `system.runtime.queries` only retains *recent* queries (in-memory ring buffer with `query.max-history` and `query.min-expire-age`) — for historical cost analysis longer than a few hours, the engineer needs the JSON event logger (`event-listener.properties`) writing to an audit/Iceberg table. r16 covers this; responder skipped it. Not load-bearing for the immediate question ("which models are most expensive last hour") but worth noting.

**Recommendation: NO-OP.**

---

## Topic durability updates

- **Query performance basics** (4.1771/23 → 4.1280/24 with Q1 3.250): margin shaves from +0.6771 to +0.6280. Still safely above 3.5 threshold but remains the THINNEST required topic. LIGHT FIX-A above directly addresses the underlying findability gap.
- **Analytical query patterns on Iceberg+Trino** (4.4748/92 → 4.4697/93 with Q2 4.000): margin -0.0051, still +0.9697 above threshold. Broken-secondary padding bounded.
- **SQL best practices for OLAP** (4.5530/203 → 4.5552/204 with Q3 5.000): margin +0.0022 lift, +1.0552 above threshold. CAST-to-integer pin durability sustaining.
- **Cost considerations** (4.3074/23 → 4.3258/24 with Q4 4.750): margin +0.0184 lift, +0.8258 above threshold.

---

## Source-verified defects this iter

| # | Defect | Source | Classification | Recommendation |
|---|---|---|---|---|
| 1 | Q1 TopN omission for `ORDER BY+LIMIT` over 200M rows; spilling-on-sort framing wrong | r18 §1418-1422 spill section is keyword-magnet for "ORDER BY+spilling" queries but does not disambiguate TopN vs full sort | resource-sourced findability gap | **LIGHT FIX-A** — additive TopN-disambiguation card in r18 next to spill section (text drafted above); watch label "r18 TopN-disambiguation iter1141" |
| 2 | Q1 `query_max_memory_per_node` "lower to spill earlier" advice | r23 §242-244 correctly defines it as lower-only hard cap, but no explicit "this is NOT a spill knob" defang | covered by the same r18 FIX-A above (defang in the same card) | folded into FIX-A #1 |
| 3 | Q2 broken-secondary extension query referencing undefined `streak_id_for_max` | known Haiku padding pattern (iter936/943/948/950/954/1013/1019/1020) | responder one-off | **NO-OP** per pinned memory directive |

---

## Q1 TopN-vs-spill assessment summary

The responder's answer is **partially mis-diagnosed mechanism + correct practical fix**. ORDER BY + LIMIT is a TopN operator (bounded heap, NOT full sort) per verified Trino 467 source. The "200M rows in a sort buffer" framing is wrong. The real bottleneck is the unfiltered TableScan. The `query_max_memory_per_node` "lower to spill earlier" advice is a backwards misconception. BUT the responder lands on the correct practical fix ("reduce input, don't just add memory") so engineer harm is bounded.

**LIGHT FIX-A warranted** because:
1. Findability is the root cause — r18 spill section is the keyword-magnet for "ORDER BY + spilling" but doesn't disambiguate TopN.
2. The misconception is specific and addressable in a small additive card (no large rewrite needed).
3. Query-perf-basics is the thinnest required topic — durability matters here.
4. The defang text is bounded and won't over-attract adjacent questions (no aggregation/join spill questions get confused by a TopN card).

---

## Teacher guidance for iter1142

1. **LIGHT FIX-A in r18 spill-to-disk section**: add the TopN-disambiguation card drafted above. Place it AFTER the existing spill-to-disk paragraphs (§1418-1422), BEFORE the FTE migration sidebar (§1480-1484). Cross-ref r23 §2387 for the determinism-context TopN mention. Keep the existing spill-to-disk content unchanged — this is an ADD, not a rewrite. The "DO NOT WRITE" block defangs both (a) the "ORDER BY + LIMIT = full sort" framing and (b) the "lower `query_max_memory_per_node` to spill earlier" misconception, in the same card.
2. **No other resource edits this iter.** Q2 broken-secondary is recurring responder padding, no resource fix; Q3/Q4 clean.
3. **Re-probe label for iter1142**: "ORDER BY+LIMIT TopN watch — `ORDER BY ts LIMIT 100` over 200M rows slow, is more memory the fix" (or similar). Confirm responder names TopN + points at TableScan inputRows + does NOT recommend lowering `query_max_memory_per_node`.

---

**Iter1141 verdict: 4.2500 PASS + LIGHT FIX-A r18 TopN-disambiguation.**
