# Judge Feedback — Iter 363 Q1

**Date**: 2026-05-29
**Phase**: extended
**Topic**: Cost considerations cloud vs on-prem (2nd angle — re-probe of iter362 Q2 with concrete dollar scenario per iter363 judge probe target #1)
**Question**: "We have ~80 TB stored in MinIO and scan ~40 TB of it per month for analytics. I need to give our VP a concrete comparison of what we'd pay on AWS (Athena + Glue + S3) versus what we're paying to run Trino + Iceberg + MinIO ourselves. Can you give me an approximate monthly cost breakdown for both options at our scale?"

---

## Scores

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 4.0 | Athena $5/TB, Glue $0.44/DPU-h, Athena Provisioned $0.30/DPU-h all CORRECT; S3 inaccurate ($23.55/TB-month flat vs actual tiered $23/TB first 50 TB + $22/TB next 30 TB — minor 4% error, gave $1,884 instead of $1,810); Glue Data Catalog API costs omitted; S3 GET/egress not addressed; Glue 10 DPU-h/day assumption arbitrary and not anchored to question scope |
| Beginner clarity | 3.0 | DPU, FTE, Provisioned Capacity, "lift-and-shift" used without inline definitions. Glossary tier (per iter362) flagged 8+ consecutive iterations across topic resources — has NOT landed for cost-considerations resource. A VP-facing breakdown should expand "DPU = Data Processing Unit (4 vCPU + 16 GB RAM)" so the VP can understand what the line items mean |
| Practical applicability | 4.0 | Strong VP-facing format with line-item totals (AWS $2,216/mo, ~$26.6k/yr; on-prem FTE-wrapped $40k-$100k/yr), explicit hardware-sunk-cost caveat, prod_info.md on-prem-only constraint invoked correctly, Provisioned Capacity alternative offered. Gaps: no S3 egress/GET callout, no Glue Catalog API costs, no MinIO all-in $/TB-mo for honest on-prem comparison, no Athena-requires-Glue-Catalog lift-and-shift constraint surfaced |
| Completeness | 4.0 | Covers S3, Athena, Glue ETL line items + provisioned alternative + on-prem FTE + on-prem-only caveat. Missing: Glue Catalog API ($1/100K objects after 1M free), S3 GET/LIST/egress, MinIO all-in storage (disks/EC/rack/power/cooling/refresh), crossover heuristic in TB/month sustained scan, lift-and-shift Glue Catalog constraint |
| **Average** | **3.75** | **MARGINAL FAIL** (below per-question 4.0 bar) |

---

## Pricing verification (via WebSearch on 2026-05-29)

| Claim | Verdict | Source |
|---|---|---|
| Athena $5/TB on-demand | CORRECT | [Amazon Athena Pricing](https://aws.amazon.com/athena/pricing/) confirms $5.00/TB engine v3, 10MB minimum/query |
| Athena Provisioned Capacity $0.30/DPU-h, 4 DPU min, since Feb 10 2026 | CORRECT | aws.amazon.com/athena/pricing |
| Glue ETL $0.44/DPU-hour | CORRECT | [AWS Glue Pricing](https://aws.amazon.com/glue/pricing/) confirms $0.44/DPU-h standard, $0.29/DPU-h Flex, 1 DPU = 4 vCPU + 16 GB RAM, 1-min minimum |
| S3 Standard $23.55/TB-month flat | INACCURATE | Actual 2026 tiered: $0.023/GB first 50 TB → $23/TB; $0.022/GB next 450 TB → $22/TB. For 80 TB: 50 × $23 + 30 × $22 = **$1,810/month**, not $1,884. Answer's flat $23.55/TB rate appears to be a $0.023/GB × 1024 GB rounding artifact — does not use tiered structure |

---

## Topic running average

(4.354 × 6 + 3.75) / 7 = (26.124 + 3.75) / 7 = 29.874 / 7 = **4.268 across 7 questions** — still PASSED above 3.5 threshold, but trajectory is downward: 4.50 → 4.450 (iter353) → 4.125 (iter362 Q2) → 3.75 (iter363 Q1) over recent angles. Cost-considerations topic is degrading as fresh angles expose 2026 pricing-anchor and resource-content gaps.

---

## Pattern observations

1. **iter363 judge probe target #1 PARTIALLY LANDED** — the probe was designed to test whether iter363 teacher action #1 (2026 AWS pricing anchors) made it into the cost-considerations resource. Three of four anchors landed correctly (Athena $5/TB, Glue $0.44/DPU-h, Athena Provisioned $0.30/DPU-h) — this is meaningful progress over iter362 Q2 where zero specific anchors landed. The S3 anchor regressed to a flat rate that misses the tiered discount. So teacher action #1 partially landed but with a tier-structure miss on S3.

2. **Glossary tier remains the longest-standing open issue (9th consecutive iteration flagged)** — DPU, FTE, Provisioned Capacity, lift-and-shift all used without inline definitions. The teacher's repeated iter354+ glossary action has not landed for cost-considerations resource. Beginner clarity took a −2.0 deduction here. The VP-facing audience makes this gap especially expensive: the engineer is going to translate this into a memo, and they need plain-English expansions of DPU, FTE, provisioned vs on-demand.

3. **MinIO all-in $/TB-mo framing still missing** — iter362 teacher action #9 ("correct storage-nearly-free on-prem framing give all-in $/TB-mo MinIO estimate") did not land. The answer correctly flags hardware as sunk cost but the VP comparison is incomplete without an estimated all-in $/TB-mo for MinIO (disks + EC overhead + rack + power + cooling + 5-yr refresh + ops). Without this, the on-prem side is artificially cheap in the comparison.

4. **Lift-and-shift constraint still not surfaced** — iter362 teacher action #10 ("Athena requires Glue Catalog or Lake Formation not arbitrary Hive Metastore") did not land. This is a critical lift-and-shift gotcha: if the engineer takes this answer at face value, they could pitch the VP on "$2,200/month AWS" and then discover during migration that all Iceberg tables registered in their on-prem Hive Metastore must be re-cataloged in Glue Catalog before Athena can query them — adding both engineering time and ongoing Glue Catalog API costs.

5. **No crossover heuristic** — iter362 teacher action #3 ("concrete crossover heuristic with dollar threshold above ~X TB scanned/month sustained self-hosted wins below ~Y TB scanned/month or spiky cloud wins") did not land. A VP-facing comparison should give the rule-of-thumb crossover so the VP understands "at our scan volume, on-prem is cheaper; below ~10 TB/mo scan, AWS would be cheaper because the FTE absorbs into fewer queries."

6. **Glue ETL line item is arbitrary** — "10 DPU-h/day" is plucked from nowhere. The question said scan ~40 TB/month; Glue is for ETL, not for query. If the engineer doesn't have Spark/Glue ETL jobs today, this $132/month line item shouldn't exist at all. If they do, it should be anchored to ingestion volume (e.g., "for ~1 TB/day Postgres-to-Iceberg incremental ingestion, ~6 DPU × 0.5 hours/day = 90 DPU-h/month × $0.44 = $40/month"). The answer's 10 DPU-h/day is unanchored and inflates the AWS number by ~6%.

---

## ITER364 TEACHER ACTIONS

**HIGH priority** (these blocked iter363 Q1 from reaching 4.0):

1. **HIGH (correctness)** — Fix the S3 pricing example to use **tiered structure** explicitly: "S3 Standard us-east-1: first 50 TB/mo at $0.023/GB (= $23/TB), next 450 TB/mo at $0.022/GB (= $22/TB), over 500 TB/mo at $0.021/GB (= $21/TB). For 80 TB: 50 × $23 + 30 × $22 = $1,810/month." Show the tier math so engineers know to recalculate for their own scale. Cite [S3 Pricing](https://aws.amazon.com/s3/pricing/).

2. **HIGH (clarity, 9TH CONSECUTIVE ITERATION FLAGGED)** — Land the inline glossary block at the top of the cost-considerations resource: DPU (Data Processing Unit = 4 vCPU + 16 GB RAM, the billing unit for Glue ETL and Athena Provisioned Capacity), FTE (Full-Time Equivalent = 1 person-year of engineering work, used to amortize ops cost), TCO (Total Cost of Ownership = all-in cost including hidden line items like ops/refresh/cooling), lift-and-shift (migrating an existing stack to a new platform with minimal architectural changes), crossover (the data-volume threshold at which one option becomes cheaper than another), on-demand vs provisioned (Athena on-demand = $5/TB scanned, no commit; provisioned = $0.30/DPU-h with 4-DPU minimum reservation), Glue Catalog (managed Hive-compatible metastore on AWS — required for Athena to discover tables, separate billing).

3. **HIGH (completeness)** — Add MinIO all-in $/TB-mo estimate to on-prem side of the comparison: "MinIO on-prem all-in: disks ($5-10/TB-mo amortized over 5 yr including replacement) + EC overhead (1.5x for EC 4+2) + rack/power/cooling (~$3-5/TB-mo) + ops time (already counted in FTE). Conservative all-in: $15-25/TB-mo raw, so 80 TB × $20 = $1,600/month on-prem storage. This is comparable to AWS S3 at this scale, not free." This corrects the misleading "hardware sunk = $0" framing.

4. **HIGH (practical applicability)** — Add lift-and-shift Glue Catalog constraint to the AWS side: "Athena cannot query Iceberg tables in arbitrary Hive Metastore — it requires either Glue Data Catalog or AWS Lake Formation. Lift-and-shift means re-registering all Iceberg tables in Glue Catalog. Glue Catalog billing: first 1M objects/accesses/month free, then $1 per 100K. For 80 TB across ~5,000 tables with daily access: well within free tier. But the catalog migration is a one-time engineering task that should be in the VP estimate." Cite [AWS Glue Pricing](https://aws.amazon.com/glue/pricing/).

**MEDIUM priority:**

5. **MEDIUM (completeness)** — Add a concrete crossover heuristic with dollar threshold at the bottom of the cost-considerations resource: "Rule of thumb (2026 pricing): if you sustain >30 TB scanned/month AND have an existing data team that can absorb the ops, on-prem wins (Athena on-demand at 30 TB/mo = $150/mo, FTE absorbs at $50k+/yr; on-prem all-in for the same workload is ~$25k/yr fully loaded). Below ~5 TB scanned/month, AWS Athena on-demand wins because the FTE cost dominates everything else. Spiky workloads (large variance month-to-month) favor cloud because you don't pay for idle capacity."

6. **MEDIUM (correctness)** — Anchor Glue ETL DPU-hour estimates to ingestion volume, not arbitrary "10 DPU-h/day". Add example: "For Postgres-to-Iceberg incremental ingestion at ~1 TB/day, expect ~4-6 DPU × 30 min/day × 30 days = ~75-90 DPU-h/month = $33-$40/month. If you don't have ETL jobs (e.g., pure ad-hoc query workload), Glue ETL is $0." This prevents the arbitrary inflation pattern.

7. **MEDIUM (completeness)** — Add S3 GET/egress to AWS side: "S3 GET requests $0.0004/1,000 (negligible at typical scan rates); S3 egress to internet $0.09/GB (significant if results leave AWS — e.g., 1 TB of query results downloaded daily = $90 × 30 = $2,700/month). Athena egresses results to your client by default, so for dashboard refreshes pulling ~100 GB/day, expect ~$270/month egress on top of $200/month scan."

**LOW priority:**

8. **LOW (environment fit)** — Reinforce prod_info.md on-prem-only hard constraint by framing the question as "for VP evaluation memo" rather than a migration plan: "Note that prod_info.md mandates on-prem-only deployment, so this comparison is purely for evaluation purposes. The numbers below help the VP understand opportunity cost, not a migration plan."

9. **LOW (completeness)** — Add a Flex execution callout for Glue ETL: "If ingestion is non-urgent (can tolerate ~10 min start delay), Glue Flex is $0.29/DPU-h instead of $0.44/DPU-h (34% savings). For nightly incremental loads, Flex is appropriate."

---

## ITER364 JUDGE PROBE TARGETS

1. **Cost considerations cloud vs on-prem 3rd angle** — re-probe with crossover-question framing: "At what scan volume per month does on-prem become cheaper than Athena on-demand?" to test whether iter364 teacher action #5 (crossover heuristic) lands. This is the 3rd-angle question that should solidify or break the cost-considerations topic; if it lands cleanly, the topic moves to "durable 3-angle" status.
2. **Cost considerations 4th angle** — MinIO all-in $/TB-mo probe: "What does MinIO actually cost us per TB-month when we count disks, EC, rack, power, and cooling?" to test whether teacher action #3 lands.
3. **CDC tier 3rd angle** (carried from iter363) — partition-scoped compaction per iter362 Q1 teacher action #5 if it lands: "We tried hourly rewrite_data_files on our CDC table but it conflicts with Debezium writes — how do we scope compaction to cold partitions only?"
4. **Trino federation glossary landing check** — 9th iteration probe still pending.
5. **Query plan optimization 3rd angle** — TableScan cost reading OR Exchange operator interpretation.

---

## Sources verified via WebSearch (2026-05-29)

- [Amazon S3 Pricing](https://aws.amazon.com/s3/pricing/) — S3 Standard tiered: $0.023/GB first 50 TB, $0.022/GB next 450 TB, $0.021/GB over 500 TB (us-east-1)
- [Amazon Athena Pricing](https://aws.amazon.com/athena/pricing/) — Confirmed $5.00/TB on-demand engine v3, $0.30/DPU-h Provisioned Capacity, 4-DPU minimum, 1-min billing intervals since Feb 10 2026
- [AWS Glue Pricing](https://aws.amazon.com/glue/pricing/) — Confirmed $0.44/DPU-h standard ETL, $0.29/DPU-h Flex (34% savings), 1 DPU = 4 vCPU + 16 GB RAM, 1-min minimum billing
- [AWS S3 Pricing 2026: Storage Classes, Per-GB Rates & Cost Guide](https://costimizer.ai/blogs/aws-s3-storage) — tiered S3 pricing example confirms tier math

---

**Iter 363 Q1: 3.75 — MARGINAL FAIL** (below per-question 4.0 bar; topic running average 4.268 still PASSED, but downward trajectory across 7 cost-considerations questions exposes the pricing-anchor + glossary + on-prem all-in framing gaps that have been flagged for 9 consecutive iterations on the clarity tier and 2 iterations on the cost-anchor tier.)

---

## Iter 363 End-of-Iteration Summary

**Iteration average**: (3.75 + 4.375) / 2 = **4.0625 — MARGINAL PASS** (above per-iteration 3.5 bar, but Q1 below per-question 4.0 bar)

### Per-question results

| Q | Topic / angle | Score | Verdict |
|---|---|---|---|
| Q1 | Cost considerations cloud vs on-prem (2nd angle: 80 TB stored / 40 TB scanned concrete dollar scenario per iter363 judge probe target #1) | 3.75 | MARGINAL FAIL |
| Q2 | Trino federation escalation (after exhausting spill_enabled + dynamic-filtering.wait-timeout, what's next?) | 4.375 | PASS |

### Pattern observations across iter 363

1. **Iter363 judge probe target #1 partially landed (cost-considerations 2nd angle)** — Athena $5/TB, Glue $0.44/DPU-h, Athena Provisioned $0.30/DPU-h pricing anchors landed correctly (3 of 4 from iter362 teacher action #1). The S3 anchor regressed to a flat $23.55/TB rate that misses the 2026 tiered structure ($23/TB first 50 TB → $22/TB next 450 TB → $21/TB over 500 TB). Net: teacher action #1 mostly landed but with one tier-structure miss.

2. **Iter363 Q2 verification clean (Trino federation escalation)** — JDBC single-split per-connector-split claim verified against trino.io docs, and dynamic-filtering.wait-timeout correctly placed at Iceberg catalog properties (not PostgreSQL catalog). This was the iter363 judge probe target #4 (Trino federation 5th-phrasing escalation when all options exhausted). The answer correctly escalated to materialization/ingestion-vs-federation tradeoff and surfaced concrete next steps (Lambda architecture, per-tenant Iceberg snapshot, etc.).

3. **Glossary tier remains the longest-standing open issue — 9TH consecutive iteration flagged** — Q1 took -2.0 beginner-clarity hit (DPU, FTE, Provisioned Capacity, lift-and-shift all undefined inline). Q2 had decent inline definitions but the Trino federation resource glossary tier remains open from iter354+ (now 9 iterations carried). This is the single highest-priority unresolved gap across the loop.

4. **MinIO all-in $/TB-mo framing still missing** — iter362 teacher action #9 did not land in iter363 cost-considerations resource. Q1 correctly flags hardware as sunk cost but the on-prem side of the VP comparison is artificially cheap without an estimated all-in ~$15-25/TB-mo for MinIO (disks + EC + rack + power + cooling + 5-yr refresh).

5. **Lift-and-shift Glue Catalog constraint still not surfaced** — iter362 teacher action #10 did not land in iter363. Critical lift-and-shift gotcha: Athena requires Glue Catalog or Lake Formation, not arbitrary Hive Metastore. Without this, the VP estimate misses both the one-time engineering cost and the ongoing Glue Catalog API costs.

6. **Crossover heuristic still missing** — iter362 teacher action #3 did not land. A VP-facing comparison should give the rule-of-thumb "at >~30 TB scanned/month sustained, on-prem wins; at <~5 TB/month or spiky, AWS wins." Without this, the answer requires the engineer to compute the crossover themselves.

7. **Glue ETL DPU-h estimate is arbitrary** — Q1's "10 DPU-h/day" is plucked from nowhere and inflates AWS by ~$132/month (~6%). Should be anchored to ingestion volume or set to $0 if there's no ETL workload.

8. **Trino federation topic running average updated** — (4.4943 × 258 + 4.375) / 259 = 4.4946 across 259 questions. Marginal increase from 4.4943 → 4.4946 over single question (negligible at this sample size). Topic remains below 4.5 per-topic threshold by 0.005 — still NEEDS WORK status. After 9 iterations of glossary flag without landing, this is the dominant blocker for topic graduation.

### Iter 364 carry-forward teacher actions (prioritized)

**HIGH priority (blocked iter363 Q1 from 4.0 bar):**

1. **Fix S3 pricing to tiered structure** — Show explicit math: 50 × $23 + 30 × $22 = $1,810 (not $1,884 flat rate). Cite aws.amazon.com/s3/pricing.
2. **Land glossary block at top of cost-considerations resource** — DPU, DPU-hour, FTE, TCO, lift-and-shift, crossover, on-demand vs provisioned, Glue Catalog. 9th consecutive iteration flagged across glossary tier.
3. **Add MinIO all-in $/TB-mo estimate to on-prem side** — Concrete $15-25/TB-mo with disks/EC/rack/power/cooling/refresh breakdown. Corrects "storage is free on-prem" misframing.
4. **Add Athena-requires-Glue-Catalog lift-and-shift constraint** — Plus Glue Catalog API pricing ($1/100K objects after 1M free).

**MEDIUM priority:**

5. **Add concrete crossover heuristic with dollar threshold** — ">30 TB/mo scanned: on-prem wins; <5 TB/mo: AWS wins; spiky: AWS wins."
6. **Anchor Glue ETL DPU-h to ingestion volume** — Not arbitrary 10 DPU-h/day. Add ~75-90 DPU-h/month for 1 TB/day Postgres CDC as concrete example.
7. **Add S3 GET/egress to AWS side** — Especially $0.09/GB egress for dashboard result downloads.

**LOW priority:**

8. **Reinforce prod_info.md on-prem-only hard constraint** in cost-considerations resource framing.
9. **Add Glue Flex callout** ($0.29/DPU-h, 34% savings, for non-urgent ingestion).

### Iter 364 judge probe targets

1. **Cost considerations 3rd angle (highest priority)** — Crossover-question framing: "At what scan volume per month does on-prem become cheaper than Athena on-demand?" Tests whether iter364 teacher action #5 lands. 3rd-angle question; if clean, cost-considerations moves to durable-3-angle.
2. **Cost considerations 4th angle** — MinIO all-in $/TB-mo probe: "What does MinIO actually cost per TB-month when we count everything?" Tests iter364 teacher action #3.
3. **CDC tier 3rd angle (carried)** — Partition-scoped compaction per iter362 Q1 teacher action #5.
4. **Trino federation glossary landing check** — 9th iteration probe still pending; teacher must land glossary before iter364 closes.
5. **Query plan optimization 3rd angle** — TableScan cost reading OR Exchange operator interpretation.

### Trajectory note

Iter360-363 iteration-average trajectory: 4.0625 → 4.000 → 4.1875 → 4.0625. Loop is stuck in 4.00-4.20 ceiling band. Ceiling break requires either (a) landing 4.5+ on both questions in same iteration, or (b) shrinking std-dev across the 2 prompts. Iter363 std-dev was 0.44 (3.75 vs 4.375) — typical of recent iterations. Single longest-standing blocker (glossary tier, 9 iterations) remains the highest-leverage teacher action for ceiling break.
