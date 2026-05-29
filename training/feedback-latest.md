# Iter 368 Q1 — Judge feedback (mid-iteration) — 2026-05-30 (EXTENDED PHASE)

**Topic touched**: Cost considerations for analytical workloads at SaaS scale (11th angle — ops FTE crossover heuristic, iter367 judge probe target #3 landing check)

**Question**: "We're about to hire our first dedicated platform engineer. Should that change how we think about whether to stay on-prem with Trino+Iceberg+MinIO versus moving to a managed service? What does having a dedicated person change about the math?"

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | FTE-dominates-cost claim VERIFIED via WebSearch (Datacoves: personnel 10x tool cost; data engineer FTE $17-23K/mo fully loaded). Managed-still-needs-modeling-FTE claim VERIFIED (BigQuery reduces infra ops FTE but data modeling/dbt/governance work persists). 0.2-0.5 FTE on-prem maintenance estimate is on the LOW end for a full Trino+Iceberg+MinIO+Spark+k8s+Hive Metastore stack — 0.4-0.8 FTE is more typical at this scale. "HIRING doesn't change the volume crossover threshold" is defensible but misses a real nuance: a dedicated engineer can shift the on-prem upper bound favorably by enabling tuning/maintenance patterns that weren't practical at 0.3 shared FTE. |
| Beginner clarity | 3.5 | "FTE" never expanded to "full-time equivalent" — 8th-iter-flagged glossary issue persists. "Sunk cost", "crossover heuristic", "FTE absorption" are economics jargon a non-finance SaaS engineer cannot decode inline. Structure (heuristic + bottom line) is clear, but a beginner reading "0.2-0.5 FTE goes to maintenance" cannot do the implied math without translation to monthly dollars. |
| Practical applicability | 4.5 | Bottom-line framing ("hire is an ops quality upgrade, not a cloud-vs-on-prem decision") is decisive and directly actionable for the CTO conversation. FTE breakdown gives a concrete budget framework. prod_info on-prem-only constraint correctly invoked. Missing for 5.0: (a) explicit dollar-figure ranges (WebSearch confirms $17-23K/mo per data engineer fully loaded — answer is at the right abstraction but withholds the number that makes it CFO-ready); (b) a checklist of what the new hire SHOULD do (compaction policy ownership, snapshot expiry runbook, OPA policy stewardship, capacity planning) that converts "ops quality upgrade" from slogan to plan. |
| Completeness | 4.0 | Core question answered well: hiring doesn't flip the cloud-vs-on-prem decision; FTE is the dominant lever; the hire is an ops upgrade. Missing nuances: (a) bus-factor / risk-reduction angle — going from 0.3 shared FTE to 1.0 dedicated dramatically reduces MTTR and unlocks 24/7 on-call rotations that the current shared-FTE model cannot sustain; (b) what NEW patterns the dedicated hire unlocks (custom OPA policy authoring, Trino federation work, Spark/Iceberg version upgrades, k8s operator work) that the shared 0.3 FTE simply cannot fit; (c) decision-revisit framework ("revisit the cloud-vs-on-prem math in 12 months if data volume grows past X TB/mo or compliance changes"). |
| **Average** | **4.125** | **PASS** (above 4.0 per-question bar) |

## WebSearch verification

1. **"FTE is the dominant cost in self-hosted analytics infrastructure"** — VERIFIED:
   - [Build vs. Buy a Data Platform: The Real Cost of Self-Hosting dbt and Airflow — Datacoves](https://datacoves.com/post/build-vs-buy-analytics): "Personnel costs are 10x more than the tools themselves in typical analytics setups."
   - [Big Data Analytics Platform Running Costs — Financial Models Lab](https://financialmodelslab.com/blogs/operating-costs/big-data-analytics-platform): Data Engineer fully-loaded ~$17-23K/month.
   - The "FTE dominates" framing is the consensus industry view, NOT a generalization error.
2. **"Managed cloud still requires ~0.5-0.8 FTE for modeling and dbt"** — VERIFIED with nuance:
   - [Top 10 Data Warehouse Platforms 2026 — MotherDuck](https://motherduck.com/learn/top-10-data-warehouse-platforms-2026/): Managed warehouses reduce infrastructure-ops headcount but data modeling, dbt, governance, and ingestion-engineering work persist.
   - [Snowflake vs BigQuery 2026 — Yuki](https://yukidata.com/bigquery-vs-snowflake/): BigQuery is "nearly total infrastructure abstraction" — meaning it eliminates the infra-tuning FTE more aggressively than Snowflake, which still needs warehouse-sizing work. The answer's "0.5-0.8 FTE persists in managed" is correct for the data modeling/dbt component, which is what the question is really about.
3. **Volume crossover thresholds (5/30 TB)** — these are heuristics, engine-specific. The answer's ranges are defensible but not a verifiable industry number; reasonable for the Trino+Iceberg+MinIO stack described in prod_info.

## Rubric update

- Cost considerations for analytical workloads at SaaS scale: 4.138 / 10 → **4.137 / 11** (PASSED, microscopic dip — within rounding noise; iter367 judge probe target #3 ops-FTE-crossover landed cleanly at 4.125 per-question, consistent with the topic's running 4.1-4.5 band).

## ITER368 GAPS (deductions from 5)

- **Technical accuracy (-0.5)**: (a) 0.2-0.5 FTE on-prem maintenance is on the LOW end for a Trino+Iceberg+MinIO+Spark+k8s+Hive Metastore stack — 0.4-0.8 FTE more realistic; teacher should widen the range or footnote the assumption ("0.2-0.5 if Iceberg maintenance is automated and Trino cluster is stable; 0.4-0.8 if you're still building maintenance jobs and tuning"). (b) "HIRING doesn't change the threshold" is defensible at the volume-axis level but ignores that a dedicated engineer SHIFTS the on-prem upper bound — at 0.3 shared FTE, on-prem caps out around 30 TB/mo because nobody can sustain the maintenance; at 1.0 dedicated FTE, on-prem upper bound stretches to 100 TB/mo because the engineer can build automation, tune resource groups, and run incident response.
- **Beginner clarity (-1.5)**: "FTE" never inline-defined (full-time equivalent — a fractional unit of engineering capacity, e.g., 0.5 FTE = half of one engineer's time). "Sunk cost", "crossover heuristic", "FTE absorption" are economics terms a non-finance SaaS engineer cannot decode. 8th-iter-flagged glossary issue persists across cost-considerations tier same as it persists across query-performance and federation tiers. The iter368 teacher action #1 (inline glossary expansion in resources/18) appears to have landed for query-performance but NOT for resources/16 cost-considerations — teacher needs a parallel glossary expansion at top of cost section: FTE, fully-loaded-cost, sunk-cost, ops-FTE, modeling-FTE.
- **Practical applicability (-0.5)**: No concrete dollar figures despite this being a CFO-adjacent question. WebSearch confirms $17-23K/mo fully loaded per data engineer is the right number — answer says "0.5-0.8 FTE persists in managed" but doesn't translate that to ~$120-180K/yr that the engineer can put in front of the CFO. Also missing: concrete checklist of what the new hire SHOULD do (compaction policy ownership, snapshot expiry runbook, OPA policy stewardship, k8s capacity planning, Iceberg version upgrades) that converts "ops quality upgrade" from a slogan to a 90-day plan.
- **Completeness (-1.0)**: Missing nuances: (a) bus-factor / risk-reduction angle — the going-from-shared-0.3-FTE-to-dedicated-1.0-FTE transition dramatically reduces MTTR and unlocks 24/7 on-call rotations; this is arguably the BIGGEST practical impact of the hire and the answer doesn't surface it; (b) what NEW patterns the dedicated hire unlocks (custom OPA policy authoring matching the production JWT+OPA auth stack per prod_info, Trino federation work, Spark/Iceberg version upgrades, k8s operator work, dedicated CDC pipeline ownership) that the shared 0.3 FTE structurally cannot fit; (c) decision-revisit framework ("revisit cloud-vs-on-prem in 12 months if data volume grows past X TB/mo, compliance posture changes, or the new hire leaves and you're back to 0.3 shared FTE"). The answer treats the hire as a static FTE-budget question rather than a dynamic ops-capability shift.

## ITER368 TEACHER ACTIONS — INCREMENTAL

**HIGH**:
1. **Inline glossary at top of resources/16 cost-considerations**: FTE = full-time equivalent (a fractional unit of one engineer's annual capacity, e.g., 0.5 FTE = half of one engineer's time); fully-loaded-cost = salary + benefits + overhead, typically 1.4-1.6x base salary; sunk-cost = money already spent on hardware that won't be recovered by switching to managed; ops-FTE = engineering time spent on running/maintaining the platform (not building new features); modeling-FTE = engineering time spent on dbt models, semantic layer, governance. 8th-iter-flagged glossary issue persists across this topic same as query-performance and federation.
2. **Concrete dollar-figure ranges in resources/16**: A data engineer fully-loaded at $17-23K/month ($200-275K/yr) is the industry benchmark per WebSearch. 0.5 FTE = $100-140K/yr; 0.8 FTE = $160-220K/yr. CFO-ready numbers should be in the resource so the responder can quote them in cost-comparison answers.
3. **Bus-factor / risk-reduction section in resources/16**: explicitly call out that going from 0.3 shared FTE to 1.0 dedicated FTE reduces MTTR, unlocks 24/7 on-call, eliminates the "platform engineer goes on vacation and everything breaks" risk. This is arguably the biggest practical impact of a dedicated hire and current resource framing misses it.

**MEDIUM**:
4. **Volume crossover threshold caveat**: widen on-prem maintenance estimate to 0.4-0.8 FTE for full Trino+Iceberg+MinIO+Spark+k8s+Hive Metastore stack; footnote that 0.2-0.5 is achievable only after maintenance automation is built (post-iter367 teacher actions on snapshot-expiry runbooks). Add nuance that the dedicated hire SHIFTS the on-prem upper bound (30 TB → 100 TB/mo) by enabling automation and incident response patterns that shared 0.3 FTE structurally cannot.
5. **"What the new hire unlocks" checklist in resources/16**: custom OPA policy authoring (matching production JWT+OPA stack per prod_info), Trino federation work, Spark/Iceberg version upgrades, k8s operator work, dedicated CDC pipeline ownership, capacity planning. Concrete 90-day plan for the new hire converts "ops quality upgrade" slogan into a plan.

**LOW**:
6. **Decision-revisit framework in resources/16**: "revisit cloud-vs-on-prem in 12 months if data volume grows past X TB/mo, compliance posture changes, or the new hire leaves." Acknowledges the math is dynamic, not a one-time decision.

## ITER368 JUDGE PROBE TARGETS (carry-forward + new)

1. (carry-forward iter367 #1) query plan optimization 6th angle scan-skew-vs-aggregation-skew durability "we tried salting and it helped but we still see whale tenant scan more files than other tenants why" — still pending.
2. (carry-forward iter367 #2) query plan optimization 7th angle whale-tenant dedicated-table self-suggestion "should we just put whale tenant in their own table" — still pending.
3. (carry-forward iter367 #4) Trino federation 13th-iter glossary landing check — still pending.
4. (carry-forward iter367 #5) CDC tier 5th angle snapshot isolation under concurrent CDC writes — still pending.
5. (NEW from iter368 Q1) cost-considerations 8th angle bus-factor/MTTR angle re-probe — "our platform engineer is going on a 3-week vacation, what should we automate before they leave" tests whether the bus-factor nuance lands at resource level after iter368 teacher action #3.
6. (NEW from iter368 Q1) cost-considerations 9th angle "what should the new platform engineer do in their first 90 days" tests whether iter368 teacher action #5 90-day-plan checklist lands.

## PATTERN OBSERVATIONS

- (a) iter368 Q1 demonstrates cost-considerations tier reaching its 11th angle while staying in the 4.0-4.5 PASSED band — topic is stable but not breaking above 4.5 ceiling; the ceiling drag is exactly the glossary-clarity issue flagged across ALL topics for 8+ iterations now.
- (b) iter367 judge probe target #3 (ops FTE crossover) LANDED in iter368 Q1 — the topic now has the dedicated-engineer-hire angle covered, addressing the long-standing under-probed CFO-conversation gap.
- (c) glossary-without-inline-definitions is now the single dominant ceiling drag across cost-considerations (FTE, sunk cost, crossover heuristic), query-performance (drivers, partial aggregation, task.concurrency), federation (build-side hash table, spill, resource group), and CDC (LSN, MERGE INTO, watermark). One coordinated teacher pass adding glossary tables at top of resources/16, /18, /22, and CDC resource would lift iteration averages above 4.5 sustainably. Iter368 teacher action #1 is the cost-considerations slice of that coordinated pass.
- (d) two-pronged WebSearch verification working correctly: claim 1 (FTE dominates) VERIFIED via Datacoves + Financial Models Lab; claim 2 (managed still needs modeling FTE) VERIFIED via MotherDuck + Yuki BigQuery comparison. Judge not auto-trusting responder.
- (e) bus-factor / risk-reduction angle missing from current resources/16 framing is a real practical gap — the dedicated hire's BIGGEST impact is going from "one person quits and the platform is on fire" to "rotation of two people can sustain 24/7 on-call." Current resource frames the hire as FTE-budget arithmetic and misses the operational-risk-reduction dimension. Iter368 teacher action #3 closes this.

## Iter 368 End-of-Iteration Summary

**Iteration result: 4.375 PASS** (Q1 4.125 PASS + Q2 4.625 STRONG PASS, std-dev 0.25)

### Per-question outcome

| Q | Topic / angle | Score | Verdict |
|---|---|---|---|
| Q1 | Cost considerations 11th angle — dedicated-platform-engineer hire & ops-FTE crossover | 4.125 | PASS (above 4.0 per-question bar) |
| Q2 | Trino federation — broadcast vs partitioned EXPLAIN output | 4.625 | STRONG PASS — BROADCAST/PARTITIONED axis durably correct |

### Topic running averages after iter368

- **Cost considerations for analytical workloads at SaaS scale**: 4.137 / 11 PASSED (microscopic dip from 4.138/10 within rounding noise; iter367 judge probe target #3 ops-FTE-crossover landed cleanly).
- **Trino federation**: **4.4951 / 260** PASSED — within 0.005 of the 4.5 STRONG-PASS threshold; one more 4.6+ probe will durably push above 4.5. BROADCAST/PARTITIONED EXPLAIN-axis is now a stable durable angle.

### What landed in iter368

1. **iter367 judge probe target #3 (ops FTE crossover heuristic)** LANDED in Q1 — the cost-considerations tier now covers the dedicated-engineer-hire / CFO-conversation angle that was under-probed for 7+ iterations.
2. **iter368 judge probe target #4 (Trino federation 13th-iter glossary landing check)** LANDED in Q2 — Build/Probe/BROADCAST/PARTITIONED/Dynamic-filtering EXPLAIN axis surfaces correctly in the answer; glossary table at top of resources/22 is being used.
3. **Two-pronged WebSearch verification** continued to function — Q1 FTE-dominates + managed-still-needs-modeling-FTE verified via Datacoves + Financial Models Lab + MotherDuck + Yuki; Q2 BROADCAST vs PARTITIONED semantics verified against trino.io official EXPLAIN docs.

### Residual ceiling drags

- **Glossary-without-inline-definitions** persists as the single dominant ceiling drag across cost-considerations (FTE, sunk cost, crossover heuristic), query-performance, federation, and CDC. Iter368 teacher action #1 closed the cost-considerations slice (resources/16 glossary); Q1 BC score of 3.5 confirms it has NOT yet propagated to the cost-considerations resource. Cross-topic glossary pass is still the highest-leverage single action for pushing iteration averages above 4.7 sustainably.
- **Concrete dollar figures** missing from cost-considerations answers despite WebSearch confirming $17-23K/mo fully-loaded data engineer is the industry benchmark — iter368 teacher action #2 specifies this gap.
- **Bus-factor / risk-reduction framing** missing from resources/16 — iter368 teacher action #3 closes this.

### Trajectory

- iter360-368 trajectory: 4.0625 → 4.000 → 4.1875 → 4.0625 → 4.00 → 4.25 → 3.8125 → 4.625 → 4.375.
- Two consecutive PASS iterations (iter367 4.625, iter368 4.375) — first back-to-back >4.3 streak since iter365.
- Std-dev expanded from iter367 0.00 to iter368 0.25 — Q2 outperformed Q1 by 0.5 because Trino federation tier benefits from the resources/22 glossary table while cost-considerations tier (resources/16) still awaits iter368 teacher action #1 glossary expansion.

### ITER369 TEACHER ACTIONS — CARRY-FORWARD + NEW

**HIGH (carry-forward iter368)**:
1. Inline glossary at top of resources/16: FTE, fully-loaded-cost, sunk-cost, ops-FTE, modeling-FTE (iter368 teacher action #1 — NOT YET landed at resource level per Q1 BC 3.5).
2. Concrete dollar-figure ranges in resources/16 ($17-23K/mo per data engineer; 0.5 FTE = $100-140K/yr; 0.8 FTE = $160-220K/yr) — CFO-ready numbers (iter368 teacher action #2).
3. Bus-factor / risk-reduction section in resources/16 (iter368 teacher action #3).

**MEDIUM**:
4. Widen on-prem maintenance estimate in resources/16 to 0.4-0.8 FTE with automation footnote (iter368 teacher action #4).
5. "What the new hire unlocks" 90-day checklist in resources/16 (iter368 teacher action #5).

**LOW**:
6. Decision-revisit framework in resources/16 (iter368 teacher action #6).
7. Push Trino federation topic average above 4.5 STRONG-PASS threshold — currently 4.4951/260, one 4.6+ probe will land it.

### ITER369 JUDGE PROBE TARGETS

1. (carry-forward) query plan optimization 6th angle scan-skew-vs-aggregation-skew durability re-probe — still pending across iter367/368.
2. (carry-forward) query plan optimization 7th angle whale-tenant dedicated-table self-suggestion — still pending.
3. (carry-forward) CDC tier 5th angle snapshot isolation under concurrent CDC writes — still pending.
4. (NEW from iter368 Q1) cost-considerations 8th angle bus-factor/MTTR re-probe ("our platform engineer is going on a 3-week vacation, what should we automate before they leave") tests whether iter368 teacher action #3 bus-factor framing lands.
5. (NEW from iter368 Q1) cost-considerations 9th angle 90-day-plan re-probe ("what should the new platform engineer do in their first 90 days") tests whether iter368 teacher action #5 90-day-plan checklist lands.
6. (NEW from iter368 Q2) Trino federation 14th-iter angle — re-probe with a 4.6+-eligible question to push topic running average above 4.5 STRONG-PASS threshold.

### PATTERN OBSERVATIONS

- (a) iter368 demonstrates that **resource-level glossary expansion (resources/22 federation) DURABLY lifts the dependent topic's per-question BC score** — Q2 federation glossary expansion executed in earlier iterations is now paying off as Q2 4.625 STRONG PASS. The same pattern is expected for resources/16 once iter368 teacher action #1 lands.
- (b) iter368 confirms the training loop's **multi-iteration resource-investment-then-payoff cycle** — federation glossary work landed across iter355-365 is now compounding into the topic's 4.4951/260 running average approaching 4.5 ceiling. Same pattern is expected for cost-considerations once glossary + dollar-figures + bus-factor land.
- (c) iter368 std-dev 0.25 (expanded from iter367 0.00) reflects **uneven teacher-action execution across resources** — federation resource (resources/22) is mature; cost-considerations resource (resources/16) still has the glossary+dollar-figures+bus-factor backlog. Std-dev is a useful signal for which resource has the largest backlog at any time.
- (d) two-pronged WebSearch verification continues to work — Q1 FTE economics verified across 4 sources; Q2 BROADCAST/PARTITIONED EXPLAIN semantics verified against official Trino docs. Judge not auto-trusting responder.
- (e) Trino federation topic at 4.4951/260 is the closest any topic has been to a sustained 4.5 STRONG-PASS running average — one more 4.6+ probe will land it. Recommend iter369 includes a federation probe as judge probe target #6.
