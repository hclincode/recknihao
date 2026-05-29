# Judge Feedback — Iter 364 Q1

**Date**: 2026-05-29
**Phase**: extended
**Topic**: Cost considerations cloud vs on-prem (3rd angle — crossover-question framing per iter363 judge probe target #1: "at what scan volume per month does on-prem become cheaper than Athena on-demand?")
**Question**: "We're trying to figure out the right time to move our analytics infrastructure to cloud vs keep it on-prem. Right now we scan about 5 TB per month. At what point does on-prem Trino+Iceberg become cheaper than AWS Athena? Is there a rule of thumb for when one stops making sense?"

---

## Scores

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 3.5 | Athena $5/TB CORRECT (verified via aws.amazon.com/athena/pricing); 5 TB × $5 = $25/mo math correct; S3 range $1,200-$2,300 roughly matches tiered math (50 TB = $1,150, 100 TB = $2,250) BUT no tier structure shown; Glue ETL $250-$300/mo arbitrary, not anchored to ingestion volume; **crossover heuristic axis confusion** — answer states "~20-40 TB stored" as the crossover threshold, but the question is framed in TB/month scanned; Athena cost scales with TB scanned (per-query), not TB stored, so a stored-TB crossover is the wrong unit; decision table uses both axes ("<10 TB stored AND <10 TB/month scanned") which is partially defensible but conflates the two cost drivers; Athena 10 MB minimum/query not mentioned; Glue Catalog API costs ($1/100K objects after 1M free) omitted; lift-and-shift constraint (Athena requires Glue Catalog, not Hive Metastore) omitted |
| Beginner clarity | 2.5 | **10th consecutive iteration flagged for glossary tier**. "DPU", "FTE", "snapshot expiry", "rollup tables", "approx_distinct", "partitioning" all used without inline definitions. The question is explicitly a decision-support / rule-of-thumb framing (likely a CTO-facing memo), and a beginner audience cannot translate "FTE $40-100k/year" without knowing FTE = Full-Time Equivalent engineer headcount cost loaded with benefits/overhead. The phrase "approx_distinct" assumes Trino SQL fluency. This is the single largest deduction on this answer and the longest-standing open issue on the cost-considerations topic |
| Practical applicability | 3.5 | Decision table provides a structured rule-of-thumb framing; on-prem-only prod_info.md constraint correctly invoked at the right moment ("you can't actually move to AWS per the documented production environment"); Trino+Iceberg-specific cost-control levers (snapshot expiry, partitioning, rollup tables, approx_distinct) are concrete and fit the production stack. **Gaps weakening decision support**: (a) crossover axis confusion (stored vs scanned) means the engineer can't translate "20-40 TB" into their actual decision math — if their 5 TB/mo scan grows to 20 TB/mo, the answer doesn't tell them which threshold applies; (b) no MinIO all-in $/TB-mo means the on-prem side is artificially cheap in the comparison ($0 hardware sunk + $40-100k FTE only); (c) no lift-and-shift Glue Catalog constraint surfaced — engineer pitching this to leadership could be blindsided during migration; (d) no S3 egress ($0.09/GB) for dashboard result downloads, which is a known production gotcha for SaaS analytics workloads |
| Completeness | 3.5 | Covers AWS line items (Athena, S3, Glue), on-prem framing (hardware sunk + FTE), crossover heuristic, decision table, prod_info.md constraint, and 4 cost-control levers. **Missing**: (a) MinIO all-in $/TB-mo for honest on-prem comparison (iter362 teacher action #9 still not landed across iter362/363/364); (b) Athena-requires-Glue-Catalog lift-and-shift constraint (iter362 teacher action #10 still not landed); (c) S3 GET/egress (especially $0.09/GB egress for dashboard downloads); (d) Athena Provisioned Capacity ($0.30/DPU-h, 4 DPU min) as an alternative for predictable workloads — iter363 Q1 had this but it regressed here; (e) Athena 10 MB minimum/query for engineers with high-cardinality small-query workloads; (f) crossover heuristic in TB/month scanned (the question's actual axis), not TB stored |
| **Average** | **3.25** | **FAIL** (below per-question 4.0 bar; topic-average 4.141 still PASSED at topic level but trajectory continues downward) |

---

## Pricing verification (via WebSearch on 2026-05-29)

| Claim | Verdict | Source |
|---|---|---|
| Athena $5/TB on-demand | CORRECT | [Amazon Athena Pricing](https://aws.amazon.com/athena/pricing/) confirms $5.00/TB engine v3, 10 MB minimum/query |
| 5 TB × $5/TB = $25/month query cost | CORRECT (math) | Per-TB math is right; does not account for 10 MB minimum-per-query floor |
| S3 50-100 TB stored ~$1,200-$2,300/month | ROUGHLY CORRECT | [S3 Pricing](https://aws.amazon.com/s3/pricing/) tiered: $0.023/GB first 50 TB → $23/TB; $0.022/GB next 450 TB → $22/TB. 50 TB = $1,150; 100 TB = $1,150 + $1,100 = $2,250. The given range matches order-of-magnitude but does not show the tier breakpoint at 50 TB |
| Glue ETL ~$250-$300/month | UNANCHORED | [AWS Glue Pricing](https://aws.amazon.com/glue/pricing/) is $0.44/DPU-h. The $250-$300/mo figure implies ~568-682 DPU-h/mo (~19-23 DPU-h/day) which is plausible for a moderate CDC ingestion workload but is not anchored to the question's 5 TB/mo scan scope |
| Crossover ~20-40 TB stored | AXIS CONFUSION | Athena cost scales with TB scanned (per-query), not TB stored. A scanned-TB crossover (e.g., "above ~30 TB/mo sustained scan on-prem wins; below ~5 TB/mo or spiky AWS wins") would directly answer the question. No external source confirms a "20-40 TB stored" rule-of-thumb — it appears to conflate storage cost ($1,150-$2,250/mo at S3 tiered rates) with FTE absorption, which is a hand-wave |

---

## Topic running average

(4.268 × 7 + 3.25) / 8 = (29.876 + 3.25) / 8 = 33.126 / 8 = **4.141 across 8 questions** — still PASSED above 3.5 threshold, but trajectory continues downward: 4.50 → 4.450 (iter353) → 4.125 (iter362 Q2) → 3.75 (iter363 Q1) → **3.25 (iter364 Q1)**. Four consecutive cost-considerations probes below 4.0. The 2026 pricing-anchor recovery is partial (Athena anchor stuck, S3 still missing tier structure, MinIO all-in still missing) and the glossary tier gap continues to dominate beginner-clarity deductions. Recommend escalating cost-considerations to top-priority teacher backlog before topic-average dips below 4.0.

---

## Pattern observations

1. **iter363 judge probe target #1 LANDED (crossover-framing axis confusion exposed)** — the probe was designed to test whether iter363 teacher action #5 (concrete crossover heuristic with dollar threshold) landed. It did not. The answer fabricated a "20-40 TB stored" heuristic that mixes the cost-driver axes (storage vs scan) and does not directly answer the question's TB/month scanned framing. The teacher needs a precise crossover table indexed on TB/month scanned (the actual Athena cost driver), not TB stored.

2. **Glossary tier remains the longest-standing open issue (10th consecutive iteration flagged)** — DPU, FTE, snapshot expiry, rollup tables, approx_distinct all used without inline definitions. The question is decision-support framing for a non-engineering audience (the engineer is figuring out what to recommend), and the beginner-clarity gap directly weakens the engineer's ability to translate the answer into a memo. Beginner clarity took a −2.5 deduction here, the largest single deduction on this answer.

3. **MinIO all-in $/TB-mo framing still missing** — iter362 teacher action #9 and iter363 teacher action #3 ("correct storage-nearly-free on-prem framing give all-in $/TB-mo MinIO estimate $15-25/TB-mo with disks/EC/rack/power/cooling/5-yr refresh") did NOT land for the 3rd consecutive iteration. The answer correctly flags hardware as sunk but the decision support is incomplete without an estimated all-in $/TB-mo for MinIO including operational TCO. Without this, the on-prem side reads as "$0 + FTE only" which is misleading.

4. **Lift-and-shift constraint still not surfaced** — iter362 teacher action #10 and iter363 teacher action #4 ("Athena requires Glue Catalog or Lake Formation, not arbitrary Hive Metastore") did NOT land for the 3rd consecutive iteration. This is a critical gotcha for any hypothetical lift-and-shift — engineer needs to know upfront that the production Hive Metastore is incompatible with Athena.

5. **2026 AWS pricing anchor regression** — iter363 Q1 had Athena Provisioned Capacity ($0.30/DPU-h, 4 DPU min) as a documented alternative pricing model. Iter364 Q1 dropped Provisioned Capacity entirely from the answer despite it being highly relevant to the question's "right time to move" framing — Provisioned Capacity changes the breakeven math significantly for predictable workloads. Suggests the 2026 pricing anchors landed in resource but are not surfacing consistently across question reformulations.

6. **Decision table is the strongest part of the answer** — the explicit "on-prem wins if hardware provisioned; AWS wins if <10 TB stored AND <10 TB/month scanned" framing is a real practical applicability win and the only part of the answer that directly addresses the question's rule-of-thumb framing. The conditions are partly correct (10 TB/month scanned is a defensible AWS-wins threshold for a no-FTE startup scenario) but the table needs the FTE assumption made explicit and the scanned-vs-stored axes separated.

7. **Trajectory concern: 4 consecutive cost-considerations probes below 4.0** — iter362 Q2 (4.125), iter363 Q1 (3.75), iter364 Q1 (3.25). Trend is monotonically decreasing as fresh probe angles expose deeper resource gaps. Topic-average 4.141 still above the 3.5 threshold but at current trajectory the topic could fall below 4.0 within 2-3 more probes.

---

## ITER365 TEACHER ACTIONS (in priority order)

### HIGH

1. **Land a crossover-heuristic table indexed on TB/month scanned (the actual Athena cost driver)** — iter362 teacher action #3, iter363 teacher action #5, NOW iter364 teacher action #1, 4th consecutive iteration flagged. Concrete dollar threshold framing:
   - **<5 TB/mo scanned**: AWS wins decisively (Athena $25/mo, no FTE; on-prem FTE $40-100k dominates)
   - **5-30 TB/mo scanned**: depends on FTE absorption; if the FTE is already employed for other work, on-prem wins; greenfield AWS wins
   - **>30 TB/mo scanned sustained**: on-prem wins decisively (Athena $150+/mo and scaling linearly vs fixed FTE + sunk hardware)
   - **Spiky/unpredictable scan patterns**: AWS wins regardless (no idle hardware cost)
   - **Predictable high-volume scanned**: Athena Provisioned Capacity ($0.30/DPU-h, 4 DPU min, $876/mo for 4 DPU 24/7) reshapes the math — add a separate row for provisioned-Athena breakeven

2. **Inline glossary at top of `resources/cost-considerations*.md` — 10th consecutive iteration flagged, longest-standing open issue on the topic.** Must define: DPU (Data Processing Unit = 4 vCPU + 16 GB RAM), DPU-hour (one DPU running for one hour, the AWS Glue billing unit), FTE (Full-Time Equivalent engineer cost loaded with benefits/overhead, typically 1.3-1.5× base salary), TCO (Total Cost of Ownership, all-in cost including hidden ops/refresh), lift-and-shift (moving existing workload to cloud unchanged vs re-architecting), on-demand vs Provisioned Capacity, Glue Catalog (AWS's managed Hive Metastore replacement, required for Athena), crossover/breakeven, sunk cost vs marginal cost.

3. **Land MinIO all-in $/TB-mo on the on-prem side** — iter362/363/364 teacher action all flagged. Recommended framing: "$15-25/TB-mo conservative all-in for MinIO: disks ($3-5/TB-mo with 5-yr refresh) + erasure-coding overhead (~33% capacity tax for EC:4+2) + rack/power/cooling ($2-4/TB-mo) + ops/monitoring (allocated FTE fraction)." Without this, the on-prem side reads as "$0 + FTE only" which is misleading vs AWS S3's $23/TB-mo line item.

4. **Land Athena-requires-Glue-Catalog lift-and-shift constraint** — iter362/363/364 teacher action all flagged. Must state plainly: "Athena requires AWS Glue Data Catalog (or Lake Formation). It cannot query Iceberg tables registered in an arbitrary Hive Metastore. A lift-and-shift to Athena requires re-registering every Iceberg table in Glue Catalog, which adds engineering time AND ongoing Glue Catalog API costs ($1 per 100K requests after 1M free)."

### MEDIUM

5. **Re-surface Athena Provisioned Capacity in cost-considerations resource** — iter363 Q1 had it, iter364 Q1 dropped it. The "right time to move" framing question is exactly where Provisioned Capacity reshapes the math. Resource should have a paragraph: "If your scan volume is predictable and >X TB/mo, Athena Provisioned Capacity ($0.30/DPU-h, 4 DPU minimum = $876/mo for 4 DPU 24/7) can be cheaper than on-demand. Crossover at ~175 TB/mo scanned (175 × $5 = $875 ≈ $876)."

6. **Add S3 egress and GET line items** — $0.09/GB egress significant for dashboard result downloads (e.g., 100 GB/day = $270/mo); $0.0004/1K GET requests generally negligible but worth one line. iter363 teacher action #7 still not landed.

7. **Anchor Glue ETL DPU-h to ingestion volume** — iter363 teacher action #6 still not landed. Resource should give worked example: "~75-90 DPU-h/month for 1 TB/day Postgres CDC ingestion to Iceberg" so engineers can scale to their actual volume rather than copying the $250/mo figure as a black box. For pure ad-hoc/no-ingestion workload, Glue ETL should be $0.

8. **Add Athena 10 MB minimum/query** — material for workloads with many small high-cardinality queries (e.g., dashboard with 100 widgets each scanning a tiny dimension table). One line in the Athena section.

### LOW

9. **Reinforce prod_info.md on-prem-only hard constraint at top of cost-considerations resource** — the iter364 Q1 answer correctly invokes it but the framing could be cleaner: "For your production environment (on-prem only per prod_info.md), cloud is a hypothetical not an option — the cost comparison below is for context only."

10. **Add Glue Flex callout ($0.29/DPU-h, 34% savings) for non-urgent ingestion** — iter363 teacher action #9 not yet probed but worth landing.

---

## ITER365 JUDGE PROBE TARGETS

1. **Cost-considerations 4th angle highest priority** — crossover heuristic re-probe with explicit TB/month scanned framing: "If our scan grows from 5 TB/mo to 50 TB/mo over the next year, at what monthly scan volume does on-prem stop being cheaper than Athena on-demand?" Tests iter365 teacher action #1.

2. **Cost-considerations 5th angle** — MinIO all-in $/TB-mo direct probe: "What is the all-in cost per TB-month of running MinIO on-prem, including disks, rack, power, cooling, and 5-year refresh?" Tests iter365 teacher action #3.

3. **CDC tier 3rd angle** — carried forward from iter362 Q1 teacher action #5 (partition-scoped compaction); now 3 iterations stale.

4. **Trino federation glossary landing check** — 10th iteration probe, still pending; teacher must land glossary before iter365 closes.

5. **Query plan optimization 3rd angle** — TableScan cost reading or Exchange operator interpretation, still pending from iter360+.

---

## Sources verified via WebSearch (2026-05-29)

- [Amazon Athena Pricing](https://aws.amazon.com/athena/pricing/) — confirms $5/TB on-demand engine v3, 10 MB minimum/query
- [Amazon Athena Pricing in 2026: Complete Cost Breakdown — Cloud Burn](https://cloudburn.io/blog/amazon-athena-pricing) — confirms $5/TB rate and 10 MB minimum guidance
- [AWS Glue Pricing](https://aws.amazon.com/glue/pricing/) — Glue ETL $0.44/DPU-h standard, $0.29/DPU-h Flex
- [Amazon S3 Pricing](https://aws.amazon.com/s3/pricing/) — confirms S3 Standard tiered pricing: $0.023/GB first 50 TB, $0.022/GB next 450 TB
- [Athena vs Snowflake on Iceberg — Yuval Yogev / Medium](https://medium.com/@yogevyuval/athena-vs-snowflake-on-iceberg-performance-and-cost-comparison-on-tpc-h-03b96fa6dbf9) — context for Iceberg query-cost comparisons; confirms Athena $5/TB economics
- [Why Your S3 Bill Jumped After You Started Doing Data Engineering — Vantage](https://www.vantage.sh/blog/s3-bill-increase-athena-trino-hive-fix-iceberg-caching) — confirms S3 GET request costs are non-negligible at scale for Iceberg queries

---

## Iter 364 End-of-Iteration Summary

**Date**: 2026-05-29
**Phase**: extended
**Iteration average**: 4.00 — MARGINAL PASS (Q1 3.25 FAIL + Q2 4.75 STRONG PASS, std-dev 1.06 — largest gap in recent iterations)

### Per-question recap

| Q | Topic / Angle | Score | Verdict | Key finding |
|---|---|---|---|---|
| Q1 | Cost considerations cloud vs on-prem — 3rd angle crossover-question framing | 3.25 | FAIL | Crossover heuristic used stored-TB as axis when question was about scanned-TB/month; correct axis is TB/month scanned (<5 TB/mo Athena on-demand wins, >30 TB/mo on-prem wins, >175 TB/mo Provisioned Capacity wins) |
| Q2 | Iceberg maintenance — partition-scoped compaction for CDC | 4.75 | STRONG PASS | 3rd CDC angle confirmed (durable-3-angle eligible); both Spark `rewrite_data_files(where => ...)` AND Trino `ALTER TABLE ... EXECUTE optimize WHERE ...` syntax verified; CORRECT vs WRONG footgun callout (partition predicate must reference partition column directly, not derived expression) |

### Patterns across iter364

1. **Bimodal answer quality continues** — Q1 3.25 vs Q2 4.75 (std-dev 1.06) is the largest gap of recent iterations. Pattern: Iceberg maintenance / CDC topics continue to land cleanly with concrete syntax and footgun callouts; cost-considerations continues to drift on axis-confusion and missing all-in framing. Iteration ceiling-break requires lifting the weak topic, not pushing the strong one higher.

2. **Cost-considerations trajectory: 4 consecutive sub-4.0 probes** — 4.125 → 3.75 → 3.25. The downward trend is monotonic as fresh probe angles expose deeper resource gaps faster than the teacher can land fixes. Topic-average 4.141 still above 3.5 PASS threshold but now within striking distance of FAIL. Escalating cost-considerations to top-priority teacher backlog for iter365.

3. **Iceberg maintenance durable-3-angle achieved** — iter364 Q2 was the 3rd successful CDC angle for partition-scoped compaction (after prior 2 angles in earlier iterations). Topic now meets "tested from at least two different angles" plus durability-confirmation criterion for ongoing PASS.

4. **Glossary tier remains the longest open issue (10 iterations flagged)** — DPU, FTE, snapshot expiry, rollup tables, approx_distinct still used without inline definitions in Q1 answer. This is the single largest deduction on cost-considerations beginner-clarity and the dominant blocker for ceiling-break.

5. **MinIO all-in $/TB-mo and Athena-Glue-Catalog lift-and-shift constraint** — 3rd consecutive iteration where iter362 teacher actions #9 and #10 did not land. These are now the highest-priority teacher gaps on the cost-considerations topic.

### Carryover to iter365

- **HIGH**: Crossover-heuristic table indexed on TB/month scanned (the actual Athena cost driver) with concrete thresholds: <5 TB/mo Athena on-demand wins, 5-30 TB/mo depends on FTE, >30 TB/mo on-prem wins, >175 TB/mo Athena Provisioned Capacity wins.
- **HIGH**: Inline glossary block at top of `resources/cost-considerations*.md` (10th iteration flagged).
- **HIGH**: MinIO all-in $/TB-mo on-prem framing ($15-25/TB-mo).
- **HIGH**: Athena-requires-Glue-Catalog lift-and-shift constraint plus Glue Catalog API pricing.
- **MEDIUM**: Re-surface Athena Provisioned Capacity, S3 egress/GET, Glue ETL DPU-h anchored to ingestion volume, Athena 10 MB minimum/query.

### Iter365 judge probe targets

1. Cost-considerations 4th angle (highest priority) — re-probe crossover with explicit TB/month scanned framing to test whether iter365 teacher actions land.
2. Cost-considerations 5th angle — MinIO all-in $/TB-mo direct probe.
3. Trino federation glossary landing check (11th iteration probe pending).
4. Query plan optimization 3rd angle — TableScan cost reading or Exchange operator interpretation.
5. CDC tier 4th angle — durable-3-angle confirmed on partition-scoped compaction; rotate to a different CDC sub-topic (e.g., late-arriving updates, MERGE INTO consistency, snapshot isolation under concurrent writes).

