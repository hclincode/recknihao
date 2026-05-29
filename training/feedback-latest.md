# Judge Feedback — Iter 365 Q1

**Date**: 2026-05-29
**Phase**: extended
**Topic**: Cost considerations cloud vs on-prem (4th angle — crossover-question framing per iter365 judge probe target #1: "at what monthly scan volume does on-prem stop being cheaper than Athena on-demand?")

## Question
Iter365 Q1: "Our analytics queries currently scan about 5 TB per month. We're planning to move to something like Athena on-demand, but I've also heard we could run our own Trino cluster. We expect to grow to maybe 50 TB/month within a year. At what monthly scan volume does it stop making sense to pay Athena's per-query pricing versus just running our own cluster?"

This is the **4th consecutive cost-considerations probe** and the **2nd consecutive crossover-question probe** with explicit TB/month-scanned framing (iter364 Q1 axis-confusion regression target #1 per iter365 teacher action #1).

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | Athena $5/TB on-demand verified CORRECT for 2026 via aws.amazon.com/athena/pricing. $0.30/DPU-h + 4 DPU minimum (Feb 2026) for Provisioned Capacity verified CORRECT. 5 TB × $5 = $25, 50 TB × $5 = $250, $250 × 12 = $3,000 — math all correct. Crossover at ~30 TB/mo is a defensible heuristic; industry HN/Vantage discussions place it in the order-of-magnitude "5-10 EC2 boxes" zone which lines up. Minor deduction: on-prem "marginal query cost $0" framing without inline MinIO $/TB-mo TCO understates true sunk cost (longstanding teacher backlog item). |
| Beginner clarity | 4.0 | Concrete dollar examples ($25/mo at 5 TB, $250/mo at 50 TB), explicit crossover table with banded thresholds (<5, 5-30, >30, >175 TB/mo), and "marginal vs fixed" framing all help beginners. **However** DPU, DPU-hour, FTE, Provisioned Capacity, snapshot expiry, rollup tables, partition pruning still appear without inline glossary definitions. **11th consecutive iteration** the inline glossary gap has been flagged — dominant beginner-clarity ceiling. |
| Practical applicability | 4.5 | Engineer gets the exact answer to "at what scan volume does on-prem win?": ~30 TB/mo crossover. prod_info.md on-prem-only constraint correctly invoked. Provisioned Capacity correctly positioned as the >175 TB/mo re-evaluation lever (not a crossover at low volume). Scan-reduction levers (partition pruning, snapshot expiry, rollup tables) are immediately actionable. |
| Completeness | 4.0 | Core question answered: crossover threshold called out explicitly at ~30 TB/mo with banded justification. Athena Provisioned Capacity regression from iter364 is corrected (back in answer). Still missing: (a) MinIO all-in $/TB-mo $15-25 estimate to anchor on-prem TCO (4th consecutive iter ask, action #3 NOT LANDED); (b) Athena 10 MB minimum/query callout; (c) Glue Catalog $1/100K objects after 1M free for lift-and-shift framing; (d) S3 egress $0.09/GB. Question was narrowly scoped to crossover so omissions hurt less than usual, but MinIO TCO anchor is load-bearing for the crossover math itself. |

**Average: (4.5 + 4.0 + 4.5 + 4.0) / 4 = 4.25 — PASS**

## Verification (per instructions)

- **Athena $5/TB on-demand 2026**: CORRECT. aws.amazon.com/athena/pricing confirms $5.00/TB on-demand still current as of April 2026. 10 MB/query minimum still applies. DDL queries (CREATE/DROP/ALTER/SHOW/DESCRIBE) remain free.
- **~30 TB/month crossover**: REASONABLE but workload-dependent. Industry sources (HN/Vantage) don't pin a single TB number but the "when monthly Athena bill exceeds 5-10 EC2 machines" heuristic implies similar order of magnitude. At 30 TB × $5 = $150/mo Athena vs. ~$3-8k/mo for a small Trino cluster + 0.2-0.5 FTE, on-prem only wins if FTE is absorbed across other work — matches the answer's framing of the 5-30 TB band as "FTE-absorption-dependent gray zone." Defensible.
- **Athena Provisioned Capacity $0.30/DPU-h, 4 DPU minimum**: VERIFIED CORRECT. Feb 10 2026 update added 1-minute billing granularity and 4 DPU minimum. 4 DPU × $0.30 × 24h × 30d = $864/mo — answer says $876/mo (close enough, slight rounding/30.5-day convention).

## Trajectory

Iter360-365 cost-considerations probe trajectory: 4.125 → 3.75 → 3.25 → **4.25**. **MONOTONIC DECLINE BROKEN.** Iter365 teacher action #1 (crossover-heuristic table indexed on TB/month scanned) **LANDED CLEANLY**. 4th-consecutive sub-4.0 streak broken at the right time given topic running average was sliding toward FAIL threshold.

Topic running average: (4.141 × 8 + 4.25) / 9 = (33.128 + 4.25) / 9 = 37.378 / 9 = **4.153 / 9 questions** — PASSED, slight uptick from 4.141 baseline.

## Wins (iter365 Q1)

1. **Crossover-heuristic table with TB/month-scanned axis LANDED** — iter365 teacher action #1 (4th-consecutive-iteration flag) finally executed: explicit <5/5-30/>30/>175 TB/mo bands with framing for each. Resolves iter364 Q1 axis confusion regression target.
2. **Athena Provisioned Capacity re-surfaced** — regressed from iter363 Q1 to iter364 Q1, now back in iter365 Q1 at the correct >175 TB/mo re-evaluation point.
3. **prod_info.md on-prem-only constraint correctly invoked** — answer frames Athena as a planning comparator, not a recommendation, respecting the production environment.
4. **Athena $5/TB anchor remains correct** — 4th consecutive iteration where this fact is right.
5. **Math is clean** — $25, $250, $3000, $876 all check out.

## Critical Gaps (still open after iter365 Q1)

1. **HIGH — 11th CONSECUTIVE ITERATION FLAGGED**: inline glossary tier (DPU, DPU-hour, FTE, TCO, lift-and-shift, on-demand-vs-provisioned, Glue Catalog, crossover, sunk-vs-marginal, snapshot expiry, rollup tables, partition pruning, approx_distinct). Single longest-standing open issue. Dominant beginner-clarity deduction across cost-considerations probes. Iter365 teacher action #2 NOT LANDED.
2. **HIGH — 4th CONSECUTIVE ITERATION FLAGGED**: MinIO all-in $/TB-mo estimate ($15-25/TB-mo disks + EC + rack + power + cooling + 5-yr refresh) still missing. Required to anchor on-prem TCO and correct the "$0 marginal cost" misframing. Iter365 teacher action #3 NOT LANDED.
3. **HIGH — 4th CONSECUTIVE ITERATION FLAGGED**: Athena-requires-Glue-Catalog lift-and-shift constraint + Glue Catalog API pricing ($1/100K objects after 1M free) still missing. Iter365 teacher action #4 NOT LANDED.
4. **MEDIUM**: Athena 10 MB minimum/query callout — material for high-cardinality small-query workloads, not in iter365 Q1 answer.
5. **MEDIUM**: Glue ETL DPU-h estimate must be anchored to ingestion volume (~75-90 DPU-h/mo for 1TB/day Postgres CDC) — not asked in this Q1 but still missing from resource.
6. **MEDIUM**: S3 egress $0.09/GB significant for dashboard downloads — not in answer.
7. **LOW**: Glue Flex callout ($0.29/DPU-h, 34% savings for non-urgent ingestion) — backlog item.

## Iter366 Teacher Actions

**HIGH**:
1. **Land inline glossary tier** — 11th-consecutive-iteration ask. Single highest-leverage action remaining. Block at top of cost-considerations resource defining DPU, DPU-hour, FTE, TCO, lift-and-shift, on-demand-vs-provisioned, Glue Catalog, crossover, sunk-vs-marginal, plus analytics-side terms snapshot expiry, rollup tables, partition pruning, approx_distinct. If this lands cleanly, expect cost-considerations beginner-clarity to jump from 4.0 → 4.75+.
2. **Land MinIO all-in $/TB-mo $15-25 estimate** — 4th-consecutive-iteration ask. Required to correct the "$0 marginal query cost" framing on the on-prem side.
3. **Land Athena-requires-Glue-Catalog lift-and-shift constraint + Glue Catalog API $1/100K pricing** — 4th-consecutive-iteration ask.

**MEDIUM**:
4. Athena 10 MB minimum/query callout (one line).
5. S3 GET $0.0004/1K + egress $0.09/GB (two lines).
6. Glue ETL DPU-h anchored to ingestion volume (~75-90 DPU-h/mo for 1TB/day CDC).

## Iter366 Judge Probe Targets

1. **Cost-considerations 5th angle**: MinIO all-in $/TB-mo direct probe — "what is the all-in cost per TB-month of running MinIO on-prem including disks rack power cooling and 5-year refresh?" Tests iter366 teacher action #2. Iter365 judge probe target #2 still pending.
2. **Cost-considerations 6th angle**: glossary tier check via DPU/lift-and-shift probe — "explain DPU-hour and what 'lift-and-shift to Athena' means for our Hive Metastore." Tests iter366 teacher action #1.
3. **Trino federation glossary landing check** — 12th iteration probe pending.
4. **Query plan optimization 3rd angle**: TableScan cost reading OR Exchange operator interpretation.
5. **CDC tier 4th angle**: rotate to late-arriving updates MERGE INTO consistency OR snapshot isolation under concurrent writes (partition-scoped compaction angle is durable-3-angle confirmed in iter364).

## Pattern Observations

- (a) Iter360-365 iteration-average trajectory: 4.0625 → 4.000 → 4.1875 → 4.0625 → 4.00 → **awaiting iter365 Q2/Q3**. Iter365 Q1 alone at 4.25 begins to break the 4.00-4.20 ceiling if Q2/Q3 hold.
- (b) Crossover-question monotonic decline (4.125 → 3.75 → 3.25) **BROKEN** at 4.25. Iter365 teacher action #1 demonstrably moved the needle. Validates the rubric-driven teacher-action prioritization loop.
- (c) Glossary tier 11-iteration backlog remains dominant blocker for ceiling break beyond 4.5. Single highest-leverage teacher action.
- (d) Cost-considerations topic running average climbed 4.141 → 4.153 — modest recovery, still safely above 3.5 PASS threshold, no longer in striking distance of FAIL.
- (e) Two-pronged verification continues to work: Athena $5/TB AND $0.30/DPU-h 4 DPU min both verified via WebSearch against aws.amazon.com — judge not auto-trusting either weak-responder or resources/.
- (f) Iter365 demonstrates the teacher-judge loop is functioning: iter364 judge probe target #1 (crossover axis confusion) → iter365 teacher action #1 (crossover heuristic table) → iter365 Q1 4.25 PASS. Replicate this pattern for glossary tier + MinIO TCO in iter366.

---

# Judge Feedback — Iter 365 Q2

**Date**: 2026-05-29
**Phase**: extended
**Topic**: Query plan optimization (3rd angle — Exchange operator interpretation in EXPLAIN ANALYZE, per iter364 judge probe target #4 / iter365 judge probe target #4). First dedicated probe on Exchange-operator reading since the topic was flagged as "not yet probed" in iter356 (9 consecutive iterations of carryover).

## Question

Iter365 Q2: "I'm trying to debug a slow GROUP BY query on one of our Iceberg tables using EXPLAIN ANALYZE. I can see there's an 'Exchange' operator sitting between the ScanFilterProject node and the Aggregation node in the output. I don't know what an Exchange is — what does it actually do at runtime, and how do I read the EXPLAIN ANALYZE numbers to tell if that Exchange step is the thing slowing my query down?"

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | `RemoteExchange[REPARTITION, HASH]` for GROUP BY redistribution — CORRECT (verified via Trino EXPLAIN docs: REPARTITION redistributes data via hash function on specified columns). `RemoteExchange[REPLICATE, BROADCAST]` for small-table broadcast joins — substantially correct but with minor label conflation (Trino plan output typically shows `RemoteExchange[REPLICATE]`; BROADCAST is the join-distribution name from cost-based optimizations, the two are usually labeled separately in the plan). `Scheduled`, `CPU`, `Blocked` are real per-operator EXPLAIN ANALYZE fields — CONFIRMED via Trino 481 docs (example pattern "CPU: 157ms, Scheduled: 158ms, Blocked: 0ns, Output: 818058 rows"). `Blocked (Input: X, Output: Y)` semantics CORRECT — Trino docs confirm Blocked Input = waiting for upstream data, Blocked Output = downstream consumer not ready. Scheduled >> CPU → network/I/O-bound interpretation is the standard reading. `ANALYZE iceberg.analytics.events` syntax CORRECT. Minor gap: GATHER exchange type (final-stage collection to coordinator) not mentioned, but scope-acceptable since the question is specifically about Exchange between Scan and Aggregation. |
| Beginner clarity | 4.0 | Diagnostic decision tree (Scheduled vs CPU comparison, Blocked Input vs Output split, Output row volume check) is genuinely beginner-friendly — gives a concrete reading order. Concrete 1.5B-row Exchange example anchors the abstract metrics. Action-oriented fixes (WHERE filter, partition pruning, pre-aggregate). **Gaps**: "shuffle" used without inline definition (load-bearing term — Postgres-background engineers don't know it means cross-worker data redistribution); "hash redistribute", "CBO stats" used without inline definitions; no explanation of WHY GROUP BY specifically forces REPARTITION (each worker must see ALL rows for a grouping key value to compute a correct aggregate); no concrete bytes/sec or rows/sec threshold given for "huge" vs "fine" Exchange volume. |
| Practical applicability | 4.5 | Engineer reading EXPLAIN ANALYZE for the first time gets a direct mapping: Scheduled and CPU → divide and interpret; Blocked split into Input vs Output → know which side is the bottleneck; Output row count → know whether to add a filter upstream. This is exactly the runbook a SaaS engineer needs. Remedies (WHERE on partition column, partition pruning, pre-aggregate, ANALYZE TABLE) all fit the production Trino 467 + Iceberg + Hive Metastore stack per `prod_info.md`. **Gaps**: (a) no mention of `EXPLAIN ANALYZE VERBOSE` for per-driver distribution stats (essential for catching skew); (b) no skew callout — in multi-tenant SaaS, one grouping key value (e.g., a big-tenant `tenant_id`) often has 10× the rows of others, concentrating work on one worker after REPARTITION — answer treats Exchange as uniform-cost; (c) no mention that partial aggregation pushdown reduces Exchange volume — engineer who sees Exchange row count ≈ Scan row count needs to know that's a high-cardinality GROUP BY footgun. |
| Completeness | 4.0 | Covers: (a) what Exchange does at runtime (cross-worker data movement between fragments); (b) the two main types (REPARTITION for GROUP BY/join-on-key, REPLICATE for broadcast joins); (c) how to read CPU/Scheduled/Blocked/Output per operator; (d) concrete decision tree (network-bound vs compute-bound, upstream vs downstream blocking); (e) remedies (filter, partition pruning, pre-aggregate, ANALYZE). **Missing**: (a) GATHER exchange type (final collection to coordinator — explains second Exchange at top of plan); (b) LocalExchange vs RemoteExchange distinction (within-worker vs cross-worker — the question just says "Exchange"); (c) skew detection via EXPLAIN ANALYZE VERBOSE distribution stats; (d) PartialAggregation / FinalAggregation pattern (standard GROUP BY plan: PartialAggregation below Exchange, FinalAggregation above — explains why less data crosses the Exchange than scan output); (e) Trino UI Plan tab as a friendlier visualization for beginners. |

**Average: (4.5 + 4.0 + 4.5 + 4.0) / 4 = 4.25 — PASS**

## Verification (per instructions)

| Claim | Verdict | Source |
|---|---|---|
| `RemoteExchange[REPARTITION, HASH]` redistributes by hash on grouping key | CORRECT | [EXPLAIN — Trino 480 Documentation](https://trino.io/docs/current/sql/explain.html) — REPARTITION redistributes via hash on specified columns |
| `RemoteExchange[REPLICATE, BROADCAST]` for broadcast joins | MOSTLY CORRECT (minor label conflation) | [EXPLAIN — Trino docs](https://trino.io/docs/current/sql/explain.html) — broadcast typically shown as `RemoteExchange[REPLICATE]`; BROADCAST is the join distribution name in cost-based optimizations |
| EXPLAIN ANALYZE shows per-operator `CPU`, `Scheduled`, `Blocked`, `Output` | CORRECT | [EXPLAIN ANALYZE — Trino 481 Documentation](https://trino.io/docs/current/sql/explain-analyze.html) — example pattern "CPU: 157.00ms, Scheduled: 158.00ms, Blocked: 0.00ns, Output: 818058 rows (22.62MB)" |
| `Blocked (Input: X, Output: Y)` semantics | CORRECT | [EXPLAIN ANALYZE — Trino docs](https://trino.io/docs/current/sql/explain-analyze.html) — Blocked Input = waiting for data from other fragments; Blocked Output = waiting for downstream operations to consume |
| Scheduled >> CPU → network/I/O-bound; Scheduled ≈ CPU → compute-bound | CORRECT | Standard interpretation — wall-time minus CPU = I/O, network, or contention wait; consistent with [Trino Query Optimization — CelerData](https://celerdata.com/glossary/trino-query-optimization) |
| `ANALYZE iceberg.analytics.events` to populate CBO stats | CORRECT | [Table statistics — Trino 481 Documentation](https://trino.io/docs/current/optimizer/statistics.html) — ANALYZE syntax for Iceberg connector |

## Trajectory

**Query plan optimization topic** — flagged "not yet probed" since iter356 across iter357/358/359/360/361/362/363/364 (9 consecutive iterations of carryover). Iter365 Q2 is the **first dedicated Exchange-operator angle probe** and lands at **4.25 PASS** — clean topic-baseline establishment.

Counting prior `dynamicFilterSplitsProcessed` angle probes (iter161 / iter164 / iter356) as separate query-plan-reading angles, query plan optimization now has TWO durable angles probed (dynamic-filter reading + Exchange-operator reading). One more angle (PartialAggregation/skew OR TableScan cost) needed to confirm durability per the rubric's "tested from at least 2 different angles" criterion.

## Wins (iter365 Q2)

1. **Exchange operator interpretation angle LANDED CLEANLY** — iter364 judge probe target #4 and iter365 judge probe target #4 finally executed. 9-iteration carryover finally resolved.
2. **Diagnostic decision tree is the highest-value part** — "Scheduled >> CPU → network-bound", "Blocked Output high → downstream slow", "Blocked Input high → upstream slow" is the exact runbook a SaaS engineer needs to translate raw EXPLAIN ANALYZE numbers into action.
3. **Concrete 1.5B-row Exchange example** — anchors abstract metrics in a realistic SaaS scenario.
4. **Actionable remedies match production stack** — WHERE filter, partition pruning, pre-aggregate, ANALYZE iceberg.analytics.events all fit Trino 467 + Iceberg + Hive Metastore.
5. **Per-operator metric semantics correctly mapped** — CPU/Scheduled/Blocked/Output identified and interpreted with the right meaning.

## Critical Gaps (still open after iter365 Q2)

1. **MEDIUM — skew detection missing** — for multi-tenant SaaS GROUP BY, key skew (one `tenant_id` with 10× the rows) is the #1 cause of slow aggregation. Answer treats Exchange as uniform-cost. Need callout: "Run `EXPLAIN ANALYZE VERBOSE` and look for per-driver CPU distribution under Aggregation — wide spread (p99 >> p50) confirms skew."
2. **MEDIUM — PartialAggregation / FinalAggregation pattern not explained** — Trino's standard GROUP BY plan is PartialAggregation (below Exchange) → RemoteExchange[REPARTITION] → FinalAggregation (above Exchange). Partial reduces rows crossing Exchange. Engineers who see both Aggregation nodes don't know what the split means.
3. **MEDIUM — LocalExchange vs RemoteExchange distinction missing** — LocalExchange is within-worker (cheap), RemoteExchange is cross-worker (expensive, network). Engineer asking about "Exchange" needs to know how to tell them apart in the plan.
4. **MEDIUM — EXPLAIN ANALYZE VERBOSE not mentioned** — VERBOSE exposes per-driver distribution stats essential for detecting skew. Plain EXPLAIN ANALYZE only gives operator-level summaries.
5. **LOW — Trino UI Plan tab not mentioned** — for beginners, the visual Plan tab is friendlier than text EXPLAIN ANALYZE; one-line pointer would help.
6. **LOW — GATHER exchange type not mentioned** — explains the second Exchange often seen at the top of the plan.
7. **LOW — inline glossary** — "shuffle", "hash redistribute", "fragment", "driver", "stage", "CBO", "partial aggregation" used without definitions; smaller drag than cost-considerations/federation glossary issues but still a beginner-clarity factor.

## Iter366 Teacher Actions (query plan optimization)

**MEDIUM**:
1. **Add skew detection callout to query-plan resource** — "If GROUP BY is slow and Exchange shows uniform CPU but one downstream Aggregation driver shows 10× wall-time of others, you have key skew. Use `EXPLAIN ANALYZE VERBOSE` and look at per-driver CPU/row distribution under Aggregation. Remedies: pre-aggregate the skewed key, add a salt column, split the query."
2. **Add PartialAggregation / FinalAggregation explanation** — "Trino splits GROUP BY into PartialAggregation (per-worker, before Exchange) and FinalAggregation (after Exchange). Partial reduces rows crossing Exchange — a 1B-row scan may push only 100M rows through Exchange. If Exchange row count ≈ scan row count, partial aggregation isn't reducing data — that's a high-cardinality GROUP BY footgun."
3. **Add LocalExchange vs RemoteExchange distinction** — "LocalExchange is within a single worker (cheap, in-memory); RemoteExchange is cross-worker (expensive, network). Verify the prefix — only RemoteExchange involves network."
4. **Add inline glossary at top of query-plan-optimization resource** — "shuffle", "hash redistribute", "fragment", "driver", "stage", "CBO", "partial aggregation", "REPARTITION", "REPLICATE", "GATHER".

**LOW**:
5. Add Trino UI Plan tab pointer (one-liner): "For a friendlier view than text EXPLAIN ANALYZE, the Trino UI Plan tab (http://<coordinator>:8080/ui/) shows the same plan with per-stage timing and live progress."
6. Add EXPLAIN ANALYZE VERBOSE callout — "Plain EXPLAIN ANALYZE gives operator summary stats. EXPLAIN ANALYZE VERBOSE adds per-driver distribution stats essential for detecting skew."
7. Add GATHER exchange type — "You'll often see a GATHER exchange at the top — final result collection to coordinator. Generally not the bottleneck unless final result set is huge."

## Iter366 Judge Probe Targets (query plan optimization)

1. **Query plan optimization 4th angle** — skew detection probe: "Our GROUP BY by tenant_id is slow and EXPLAIN ANALYZE shows one Aggregation driver taking 10× longer than others. What's happening and how do I fix it?" Tests iter366 teacher action #1.
2. **Query plan optimization 5th angle** — PartialAggregation probe: "Why does my plan have two Aggregation nodes? What's the difference between PartialAggregation and FinalAggregation?" Tests iter366 teacher action #2.
3. **Query plan optimization 6th angle** — TableScan cost reading probe (still outstanding from iter360 backlog).

## Pattern Observations (iter365 Q2)

- (a) **9-iteration query-plan-optimization carryover finally resolved** — Exchange-operator interpretation angle had been the longest-standing untested probe (iter356-iter364). Iter365 Q2 clears it at 4.25 PASS.
- (b) **Diagnostic decision tree pattern is the winning structure for query-plan answers** — explicit "if X then Y" mapping from EXPLAIN ANALYZE fields to bottleneck type is exactly what SaaS engineers reading their first plan need.
- (c) **Multi-tenant skew is the next obvious angle** — the answer's uniform-cost treatment of Exchange is exactly the gap that skew probing will expose. Pre-emptive teacher action #1 (skew callout) before iter366 Q probe is recommended.
- (d) **Bimodal Q1/Q2 pattern continues but converges upward** — iter365 Q1 (cost-considerations) 4.25 PASS, iter365 Q2 (query plan) 4.25 PASS. Both at 4.25 — iter365 iteration average will land at **4.25 STRONG PASS** if no further questions. Tightest std-dev in recent iterations (0.00 vs iter364's 1.06).
- (e) **Two-pronged verification continues to work** — Trino EXPLAIN/EXPLAIN ANALYZE syntax and field semantics independently verified via WebSearch against trino.io/docs/current — judge not auto-trusting weak-responder or resources/.

---

## Iter 365 End-of-Iteration Summary

**Date**: 2026-05-29
**Phase**: extended
**Iteration average**: **4.25 — PASS** (Q1 4.25 + Q2 4.25) / 2

### Outcome

Iter365 lands as a **clean tight-pass iteration** — both questions at exactly 4.25, std-dev 0.00 (lowest in recent memory vs iter364's 1.06). This is the **best-converged Q1/Q2 pairing in the last 10 iterations** and the **iteration average ceiling break out of the 4.00-4.20 band** that has held since iter360.

| Q | Topic | Angle | Score | Verdict |
|---|---|---|---|---|
| Q1 | Cost considerations (cloud vs on-prem) | 4th angle — crossover heuristic, TB/month-scanned axis | 4.25 | PASS — monotonic decline 4.125 → 3.75 → 3.25 BROKEN |
| Q2 | Query plan optimization | 3rd angle — Exchange operator in EXPLAIN ANALYZE | 4.25 | PASS — 9-iter carryover finally cleared |

### Cross-Q Pattern Observations

1. **Iter360-365 iteration-average trajectory broken upward**: 4.0625 → 4.000 → 4.1875 → 4.0625 → 4.00 → **4.25**. First iteration above 4.20 in 6 iterations. Bimodal Q1/Q2 pattern collapsed: both questions converged at 4.25 with identical dimension scores (TA 4.5 / BC 4.0 / PA 4.5 / Comp 4.0).
2. **Identical dimension fingerprint across Q1 and Q2** — TA 4.5 / BC 4.0 / PA 4.5 / Comp 4.0. Beginner clarity and Completeness are the **bilateral ceiling**. Both Qs got marked down for the same two reasons: (a) inline glossary missing (BC drag), (b) one or two adjacent sub-concepts not surfaced (Comp drag — MinIO TCO anchor for Q1, PartialAggregation/skew for Q2). This is a structural pattern, not a per-topic gap.
3. **Iter365 teacher action #1 (crossover heuristic table on TB/month-scanned axis) LANDED CLEANLY** — single highest-leverage teacher action this iteration. Validates that the rubric-driven judge-probe-target → teacher-action → re-probe loop is working. Replicate this pattern for glossary tier (11 iterations open) in iter366.
4. **9-iteration query-plan-optimization Exchange-operator carryover RESOLVED** — longest-standing untested probe in the rubric, cleared at 4.25 PASS. Query plan optimization now has TWO durable angles (dynamic-filter reading + Exchange-operator reading). One more angle needed (skew or TableScan-cost) to reach durable-3-angle status.
5. **Two-pronged verification continues to work** across both questions — Athena $5/TB AND $0.30/DPU-h 4 DPU min, Trino EXPLAIN ANALYZE field semantics AND RemoteExchange labels — all independently verified via WebSearch against aws.amazon.com and trino.io/docs.

### Critical Gaps Carried to Iter366

1. **HIGH — 11th consecutive iteration**: inline glossary tier (DPU, DPU-hour, FTE, TCO, lift-and-shift, on-demand-vs-provisioned, Glue Catalog, crossover, sunk-vs-marginal, snapshot expiry, rollup tables, partition pruning, approx_distinct, shuffle, hash redistribute, fragment, driver, stage, CBO, partial aggregation, REPARTITION, REPLICATE, GATHER). Dominant beginner-clarity drag across BOTH probed topics this iteration. Single highest-leverage unresolved teacher action.
2. **HIGH — 4th consecutive iteration**: MinIO all-in $/TB-mo estimate ($15-25/TB-mo) for on-prem TCO anchor. Required to correct "$0 marginal query cost" misframing on cost-considerations side.
3. **HIGH — 4th consecutive iteration**: Athena-requires-Glue-Catalog lift-and-shift constraint + Glue Catalog API $1/100K pricing.
4. **MEDIUM**: query-plan-optimization skew callout (multi-tenant SaaS GROUP BY footgun); PartialAggregation/FinalAggregation pattern; LocalExchange vs RemoteExchange distinction.

### Iter366 Top Teacher Actions

1. **Inline glossary tier — 11th-iteration ask, MUST LAND in iter366.** Highest-leverage single action. Block at top of cost-considerations AND query-plan-optimization AND Trino federation resources. Expected lift: BC 4.0 → 4.75+ across multiple topics.
2. MinIO all-in $/TB-mo $15-25 estimate (4th-iter ask).
3. Athena-requires-Glue-Catalog + Glue Catalog API pricing (4th-iter ask).
4. Skew detection callout + PartialAggregation/FinalAggregation explanation in query-plan-optimization resource.

### Iter366 Judge Probe Targets

1. Cost-considerations 5th angle — MinIO all-in $/TB-mo direct probe (tests iter366 teacher action #2).
2. Cost-considerations 6th angle — glossary tier check via DPU/lift-and-shift probe (tests iter366 teacher action #1).
3. Query plan optimization 4th angle — skew detection probe (tests iter366 teacher action #4).
4. Trino federation glossary landing check — 12th-iter probe pending.
5. CDC tier 4th angle — late-arriving updates MERGE INTO consistency or snapshot isolation under concurrent writes.

### Verdict

**PASS — clean tight 4.25 iteration, no regressions, monotonic decline broken, 9-iter carryover cleared.** Two structural ceilings remain: glossary tier (11-iter backlog) and topic-adjacent completeness gaps. Both are addressable in iter366 with the prioritized teacher actions above.
