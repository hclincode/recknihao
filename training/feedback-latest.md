# Judge Feedback — Iter 362 Q1 (EXTENDED phase, mid-iteration)

**Date**: 2026-05-29
**Phase**: EXTENDED
**Topic probed**: Postgres-to-Iceberg ingestion — CDC + maintenance interaction (Debezium concurrent writes vs `rewrite_data_files` compaction). Tests iter361 judge probe target #1 (CDC tier 2nd-angle re-probe after iter359 Q2 baseline).

## Question
"We have Debezium streaming changes from Postgres into our Iceberg tables continuously. I know we need to run compaction on Iceberg tables, but I'm worried about the compaction conflicting with the live Debezium writes. How often should we compact tables that have active CDC writes, and is there any risk of data corruption or lost changes if compaction runs while Debezium is still writing?"

## Score: 4.50 — PASS (well above per-question 4.0 bar)

| Dimension | Score |
|---|---|
| Technical accuracy | 5.0 |
| Beginner clarity | 4.0 |
| Practical applicability | 4.5 |
| Completeness | 4.5 |
| **Average** | **4.50** |

## WebSearch verification (judge due-diligence)

1. **Iceberg ACID + concurrent compaction safety** — CONFIRMED per [Reliability — Apache Iceberg](https://iceberg.apache.org/docs/1.6.0/reliability/) and [Manage concurrent write conflicts in Apache Iceberg on AWS Glue — AWS Blog](https://aws.amazon.com/blogs/big-data/manage-concurrent-write-conflicts-in-apache-iceberg-on-the-aws-glue-data-catalog/): Iceberg uses optimistic concurrency with atomic metadata-file swap. Compaction writes new files and never modifies old files. Readers see a consistent snapshot. The answer's "zero data loss / zero corruption" framing is correct.
2. **CommitFailedException + retry behavior** — CONFIRMED per [Handling Commit Conflicts in Apache Iceberg — Ryft](https://www.ryft.io/blog/handling-commit-conflicts-in-apache-iceberg-patterns-and-fixes) and [Iceberg Concurrent Write Handling](https://iceberglakehouse.com/iceberg/iceberg-concurrent-writes/): `commit.retry.num-retries` defaults to 4 with exponential backoff 100ms→60s. The answer's "4–12 retries" recommendation is a valid tunable range for higher-concurrency CDC tables. The retry only repeats the metadata commit, not the entire transaction — answer correctly describes this.
3. **Iceberg 1.8.0 release date** — CONFIRMED 2025-02-13 per [Releases — Apache Iceberg](https://iceberg.apache.org/releases/). `remove-dangling-deletes` available in 1.8+.
4. **Issue #12838** — CONFIRMED per [RewriteDataFiles with merging equality deletes · Issue #12838](https://github.com/apache/iceberg/issues/12838). Equality deletes can persist across partitions due to sequence-number logic; affects 1.5.x. The `rewrite-all=true` workaround is correctly named.

## What landed (wins)

- **Top-line ACID-safety answer matches what the engineer needs to hear first.** "No data corruption, no lost changes" framing with immutable Parquet + atomic snapshot commit + snapshot isolation chain — this is exactly the right reassurance for a CDC engineer worried about concurrent compaction. Diagnosis-first ordering is correct.
- **CommitFailedException with retry semantics correctly described.** Iter362 answer correctly explains that Iceberg retries the metadata commit (not the transaction) and that `commit.retry.num-retries` is the tunable knob. The 4-12 range recommendation is reasonable for high-CDC tables.
- **Frequency table by write rate is concretely actionable.** <10 ops/sec → nightly, 10-100 → daily, >100 → hourly — engineer can map their Debezium throughput to a cadence immediately. This directly addresses iter361 rubric gap #1 (CDC tier 2nd-angle still pending).
- **Small-files math (288 files/day per partition from 5-min micro-batches)** — makes the "why compaction" question tangible. Beginner-friendly framing.
- **Equality-delete bug callout (issue #12838 + rewrite-all=true workaround)** — correctly pinned to production Iceberg 1.5.2 per `prod_info.md`. This is high-value production knowledge that an engineer running CDC on 1.5.2 needs to know now, not after they hit the bug.
- **1.8 forward-looking `remove-dangling-deletes` reference with correct release date** — gives engineer a concrete upgrade target for when 1.8 lands.
- **Full Spark CALL syntax maintenance runbook** — copy-pasteable, ties nightly + weekly cadence together.

## Critical gaps (deductions from 5)

### Technical accuracy (0 deduction — fully correct)
All major claims verified against Apache Iceberg docs and the AWS Glue concurrent-write conflicts guide. No factual errors detected this answer.

### Beginner clarity (−1.0)
- **"snapshot isolation", "equality-delete", "MoR" used without inline definitions.** A SaaS engineer with no OLAP background reading the answer cold cannot tell what "snapshot isolation" means without external lookup. Inline glossary at top of `resources/19-postgres-iceberg-ingestion.md` (or wherever this question's answer is sourced) for: "snapshot isolation", "atomic commit", "optimistic concurrency", "equality delete", "position delete", "MoR / Merge-on-Read", "dangling delete".
- **"CommitFailedException" introduced without explaining what would happen to the engineer's pipeline if it fires** — does Debezium retry? Does it fail the connector? Does the engineer need to add a try/catch? The answer says "retry" but doesn't make clear whether the retry is automatic at the Iceberg level (it is) or requires connector-side handling (it doesn't for the Iceberg sink).

### Practical applicability (−0.5)
- **On-prem k8s Spark deployment specifics not surfaced.** The Spark CALL syntax is correct, but the answer doesn't tie it to `SparkApplication` CR / Spark Operator on the k8s cluster per `prod_info.md`. Engineer needs to know how to wrap the CALL in a `SparkApplication` resource or a CronJob on the on-prem cluster.
- **No callout on whether compaction conflicts with Debezium can exhaust the retry budget under high-write CDC.** Per AWS Glue blog: "for conflicts between streaming ingestion and compaction operations, snapshot isolation does not provide any additional benefits to the default serializable isolation." Under sustained high-write CDC + concurrent compaction, retry budget exhaustion IS possible and the answer should warn that >100 ops/sec tables may need either (a) partition-filter compaction (`where = 'partition_date > current_date - 7'`) to scope the compaction to cold partitions Debezium isn't actively writing to, or (b) higher `commit.retry.num-retries` + larger `commit.retry.max-wait-ms`.
- **Hive Metastore + MinIO production stack** not explicitly tied to the Iceberg catalog used for compaction (`CALL system.rewrite_data_files('hive.<schema>.<table>')`). The example should match the production catalog name.

### Completeness (−0.5)
- **Partition-scoped compaction (`where` clause on `rewrite_data_files`)** not surfaced. This is the standard technique for avoiding compaction-vs-CDC conflicts on partitioned tables — compact yesterday's partition while Debezium writes today's. Should be Step 1 in the runbook for CDC tables.
- **`write.distribution-mode = 'hash'` table property** not mentioned as a CDC-specific tuning knob. For Debezium tables with a primary key, `hash` distribution on the key reduces equality-delete fan-out at write time, which in turn reduces the work `rewrite_data_files` has to do.
- **`write.target-file-size-bytes` tuning** for CDC tables not mentioned. Default 512MB may be too large for high-rotation CDC tables where compaction needs to scan smaller windows; 128MB-256MB is often a better starting point.
- **`rewrite_position_delete_files` procedure** not in the runbook. After `rewrite_data_files` on a CDC table, position deletes accumulate against the new data files; `rewrite_position_delete_files` is the dedicated procedure for compacting those (introduced for exactly this CDC workload). Should be in the nightly maintenance sequence alongside `rewrite_data_files` and before `expire_snapshots`.

## Topic running average

Postgres-to-Iceberg ingestion: prior avg 4.523 across 132 questions → new avg = (4.523 × 132 + 4.50) / 133 = (597.036 + 4.50) / 133 = 601.536 / 133 = **4.522 across 133 questions**. Status: **PASSED** (well above 3.5 baseline threshold; CDC sub-tier now has 2 angles tested — iter359 Q2 baseline 4.375 + iter362 Q1 4.50 — confirming durability under reformulation).

## Iter362 teacher actions (priority-ordered)

### HIGH
1. **Inline glossary at top of `resources/19-postgres-iceberg-ingestion.md`** (or the CDC-section sub-resource) for: "snapshot isolation", "atomic commit", "optimistic concurrency", "CommitFailedException", "equality delete", "position delete", "MoR / Merge-on-Read", "dangling delete", "compaction". Mirrors the long-standing `resources/22` glossary gap — beginner clarity is the single −1.0 deduction this answer.
2. **Add partition-scoped compaction (`where` clause)** as Step 1 of the CDC maintenance runbook: `CALL system.rewrite_data_files(table => 'hive.cdc.orders', where => 'event_date < current_date - 1', options => map('rewrite-all', 'true'))`. This is the standard technique for avoiding compaction-vs-Debezium retry exhaustion under high-write CDC and was missing from the answer.
3. **Add retry-budget-exhaustion callout for high-write CDC.** At >100 ops/sec, compaction-vs-CDC commit conflicts can exhaust the default retry budget even though no data is lost. Document: (a) raise `commit.retry.num-retries` to 10-20, (b) raise `commit.retry.max-wait-ms` to 120000ms, (c) use partition-scoped compaction to physically separate compaction from active CDC partitions. Cite [AWS Glue concurrent-write conflicts blog](https://aws.amazon.com/blogs/big-data/manage-concurrent-write-conflicts-in-apache-iceberg-on-the-aws-glue-data-catalog/) as authoritative source.

### MEDIUM
4. **Add `rewrite_position_delete_files` to the nightly maintenance sequence** for CDC tables. After `rewrite_data_files`, position deletes accumulate against new data files and need their own compaction procedure. Sequence should be: `rewrite_data_files` → `rewrite_position_delete_files` → `expire_snapshots` → `remove_orphan_files` (weekly).
5. **Add CDC-specific table properties section**: `write.distribution-mode = 'hash'` on the primary key column (reduces equality-delete fan-out), `write.target-file-size-bytes = 134217728` (128MB) for high-rotation CDC tables (smaller than the 512MB default makes compaction scan windows tractable).
6. **Tie Spark CALL examples to the production catalog**: use `hive.<schema>.<table>` (matching the Hive Metastore-backed Iceberg catalog per `prod_info.md`) consistently in the runbook. Wrap the CALL in a `SparkApplication` CR template for the on-prem k8s Spark Operator deployment so engineer can deploy the maintenance job directly.

### LOW
7. **Add a Debezium-Iceberg-sink-specific note** clarifying that the Iceberg sink connector's retry behavior is governed by Iceberg's `commit.retry.*` properties at the table level — the connector itself does not need additional retry configuration for compaction conflicts. This answers the implicit "do I need to do anything in the connector config?" follow-up.

## Iter362 judge probe targets (under-tested topics still open)

1. **Trino federation 5th-phrasing escalation** — "cluster spill enabled AND SET SESSION spill_enabled=true AND OOM still happens — what next?" to test escalation path past spill (larger workers, resource group concurrency cap, Postgres-to-Iceberg ingest rewrite).
2. **Trino federation glossary landing check** — 8TH iteration probe re-probe with question requiring inline terminology definitions e.g. "what is build-side hash table and why does spill help with it?". Glossary at top of `resources/22` has been flagged for 7 consecutive iterations.
3. **Query plan optimization 3rd angle** — TableScan cost reading OR Exchange operator interpretation to keep two-angle durability extending past iter360-iter361.
4. **Cost considerations cloud vs on-prem** — AWS S3+Athena+Glue lift-and-shift vs on-prem Trino+Iceberg+MinIO TCO. Still not probed since rubric flag.
5. **Connector-fit correctness re-probe** — ask a query plan tuning question against an explicitly Iceberg-only stack to test whether JDBC-only property mistake (iter361 Q2) recurs.
6. **CDC partition-scoped compaction probe** — if iter362 teacher action #2 lands, probe at iter363+ with "we tried hourly `rewrite_data_files` on our CDC table but it conflicts with Debezium writes — how do we scope compaction to cold partitions only?" to test partition-where-clause landing.

## Sources verified via WebSearch

- [Reliability — Apache Iceberg](https://iceberg.apache.org/docs/1.6.0/reliability/) — ACID via atomic metadata-file swap, optimistic concurrency confirmed
- [Manage concurrent write conflicts in Apache Iceberg on the AWS Glue Data Catalog — AWS Blog](https://aws.amazon.com/blogs/big-data/manage-concurrent-write-conflicts-in-apache-iceberg-on-the-aws-glue-data-catalog/) — streaming-vs-compaction conflict patterns, retry behavior, snapshot isolation nuance for streaming
- [Handling Commit Conflicts in Apache Iceberg: Patterns and Fixes — Ryft](https://www.ryft.io/blog/handling-commit-conflicts-in-apache-iceberg-patterns-and-fixes) — `commit.retry.num-retries` default 4, retry only repeats metadata commit
- [Iceberg Concurrent Write Handling — Iceberg Lakehouse KB](https://iceberglakehouse.com/iceberg/iceberg-concurrent-writes/) — default 4 attempts, exponential backoff 100ms→60s, defaults stop being enough at higher concurrency
- [Releases — Apache Iceberg](https://iceberg.apache.org/releases/) — Iceberg 1.8.0 release date 2025-02-13 confirmed
- [Release apache-iceberg-1.8.0 — GitHub](https://github.com/apache/iceberg/releases/tag/apache-iceberg-1.8.0) — 1.8.0 release artifact
- [RewriteDataFiles with merging equality deletes · Issue #12838 — GitHub](https://github.com/apache/iceberg/issues/12838) — dangling equality-delete bug across partitions in 1.5.x, 1.8 remove-dangling-deletes as fix path

---

# Judge Feedback — Iter 362 Q2 (EXTENDED phase, mid-iteration)

**Date**: 2026-05-29
**Phase**: EXTENDED
**Topic probed**: Cost considerations cloud vs on-prem — AWS Athena+Glue+S3 lift-and-shift vs on-prem Trino+Iceberg+MinIO TCO. Tests iter361 judge probe target #3 (still not probed across iter357-iter361 — first probe of this angle).

## Question
"We're currently running Trino + Iceberg + MinIO all on-prem on Kubernetes. Our VP of Engineering is asking us to evaluate moving to AWS — specifically using Athena + Glue + S3 instead of managing everything ourselves. What would the cost model look like for AWS vs our on-prem setup? Are there situations where one is clearly cheaper than the other?"

## Score: 3.875 — FAIL (below per-question 4.0 bar)

| Dimension | Score |
|---|---|
| Technical accuracy | 4.0 |
| Beginner clarity | 4.0 |
| Practical applicability | 4.0 |
| Completeness | 3.5 |
| **Average** | **3.875** |

## WebSearch verification (judge due-diligence)

1. **Athena pricing per-TB-scanned** — CONFIRMED **$5.00 per TB on-demand** per [Amazon Athena Pricing — AWS](https://aws.amazon.com/athena/pricing/). 10 MB minimum per query, rounded up to nearest MB. DDL queries free. Failed queries still charged for data scanned up to point of failure. Provisioned Capacity (as of Feb 10, 2026): **$0.30/DPU-hour with 1-minute billing and 4 DPU minimum** — AWS claims up to 95% savings for short-duration workloads. Answer's "per-TB-scanned" framing is directionally correct but is missing the $5/TB anchor and the new Provisioned-Capacity option.
2. **Glue DPU-hour pricing** — CONFIRMED **$0.44 per DPU-hour** (Flex execution $0.29) with 1-second billing, 1-minute minimum per [AWS Glue Pricing — AWS](https://aws.amazon.com/glue/pricing/). Glue Data Catalog: first 1M objects/accesses free, then **$1 per 100K** objects/accesses. Answer's "per DPU-hour" framing is directionally correct but is missing the $0.44 anchor and the Data Catalog object/access charges, which matter for high-table-count lakehouses.
3. **General on-prem vs cloud cost framing** — CONFIRMED across the 2026 Athena/Glue cost-breakdown references — pay-per-query (cloud) wins at low/spiky workloads; sustained moderate-to-high throughput tilts toward owned capacity once amortization is included. Answer's qualitative crossover direction is correct. The "FTE doesn't go to zero with managed services" point is well-known and correct.

## What landed (wins)

- **Qualitative cost model framing is accurate** — on-prem is capital-heavy with sunk compute capacity and engineering FTE dominating; cloud is per-TB scanned (Athena), per DPU-hour (Glue), per TB/month (S3). All three pricing axes are correctly named.
- **Crossover heuristic direction is right** — very low volume → cloud cheaper; sustained moderate-to-high → self-hosted wins. Matches the textbook lakehouse-TCO conclusion that other cost-considerations questions in iter6/iter7 also landed.
- **FTE honesty** — the answer explicitly notes you cannot reduce engineering headcount to zero by moving to managed services if you still own the data model. This is a common executive-conversation trap, and the answer surfaces it correctly.
- **prod_info.md hard constraint correctly invoked** — on-prem-only deployment is a hard requirement per `prod_info.md`. The answer correctly flags that even if the VP wants to evaluate AWS, the production environment does not permit cloud deployment. Right environment-fit framing.
- **Honest about resource limitation** — the answer explicitly states that resources/ do not contain Athena/Glue pricing specifics and redirects to "model AWS costs externally" rather than fabricating pricing. Correct behavior under uncertainty, and aligned with the iter354+ pattern of preferring honest "I don't have that data" over confident-wrong.

## Critical gaps (deductions from 5)

### Technical accuracy (−1.0)
- **No specific 2026 dollar anchors**, even though the question explicitly asks "what would the cost model look like":
  - Athena on-demand $5/TB scanned — not stated.
  - Athena Provisioned Capacity (Feb 10, 2026): $0.30/DPU-hour, 4 DPU min, 1-minute billing — not stated; this materially changes the crossover math for sustained workloads.
  - Glue ETL DPU-hour $0.44 (Flex $0.29) — not stated.
  - Glue Data Catalog: 1M objects/accesses free tier, then $1 per 100K — not stated; matters for lakehouses with many tables and partitions.
- **"Storage nearly free" on-prem is misleading** — MinIO needs disks (3x replication or erasure coding), hardware refresh cycle (~5 yr), rack/power/cooling, and 24/7 ops. All-in $/TB-month for on-prem MinIO is non-trivial, not ~zero. The answer's framing understates on-prem storage TCO.

### Beginner clarity (−1.0)
- **"DPU", "FTE", "crossover", "lift-and-shift" used without inline definitions**. A SaaS engineer with no AWS background needs to know:
  - DPU = Data Processing Unit (4 vCPU + 16 GB RAM in the Glue/Athena context); DPU-hour is the Glue/Athena Provisioned-Capacity billing unit.
  - FTE = Full-Time Equivalent engineer (the staffing-cost unit).
  - Crossover = the workload size at which one cost model overtakes the other.
  - Lift-and-shift = migrating a workload to a cloud equivalent service without re-architecting.

### Practical applicability (−1.0)
- **The "framework to actually answer VP's question" is correct in spirit but leaves the engineer with the entire modeling job**: "measure current workload, model AWS costs externally, calculate on-prem FTE honestly." A higher-applicability answer would give:
  - Concrete current rates ($5/TB Athena, $0.44/DPU-h Glue, $0.023/GB-mo S3 Standard US East),
  - A worked sample for a representative workload (e.g., "100 TB stored, 50 TB scanned/month, 200 queries/day → ~$X/mo Athena + $Y/mo Glue + $Z/mo S3 vs ~$N/mo on-prem all-in"),
  - A clear crossover number ("above ~X TB scanned/month sustained, self-hosted wins").
- No mention of the Athena Provisioned-Capacity option that just launched Feb 10, 2026 — this is the most recent material pricing change and is exactly what the VP's evaluation needs to factor in.

### Completeness (−1.5)
- **Missing cost categories that materially affect the comparison**:
  - S3 request costs (GET/LIST/PUT) — high-fanout small-file Iceberg scans hit these hard. Real gotcha.
  - Data egress: $0.09/GB to internet, $0.02/GB cross-region — relevant if BI tools or the SaaS product live outside AWS.
  - Glue Catalog API calls beyond 1M free tier — Iceberg metadata operations hit the catalog frequently at $1/100K accesses.
  - Athena workgroup limits / concurrency — affects whether Athena can replace Trino at the engineer's throughput target at all.
- **Lift-and-shift constraints not surfaced** — Athena requires Glue Catalog (or Lake Formation); arbitrary Hive Metastore is not supported as an Athena catalog. The migration is not a pure storage move — the production Iceberg + Hive Metastore stack would need migration to Glue Catalog to be usable by Athena.
- **No concrete crossover heuristic with dollars or scale tier** — the VP wants a number. "Cloud cheaper at low volume, on-prem cheaper at high volume" is not actionable enough to support an evaluation memo.

## Topic running average

Cost considerations for analytical workloads at SaaS scale: prior avg 4.450 across 5 questions → new avg = (4.450 × 5 + 3.875) / 6 = (22.250 + 3.875) / 6 = 26.125 / 6 = **4.354 across 6 questions**. Status: **PASSED** (well above the 3.5 baseline threshold; topic average dropped 0.096 from 4.450 because the iter362 first probe on the cloud-vs-on-prem angle landed below per-question 4.0 bar). Topic gained a 6th angle (cloud-vs-on-prem TCO) but lost ground on the running avg by 0.096.

## Iter362 teacher actions for cost-considerations topic (NEW)

### HIGH
1. **Add 2026 AWS pricing anchors to a cost-considerations resource**: Athena $5/TB on-demand; Athena Provisioned Capacity $0.30/DPU-hour (4 DPU min, 1-min billing, available since Feb 10, 2026); Glue ETL $0.44/DPU-hour (Flex $0.29); Glue Data Catalog 1M free then $1/100K objects/accesses; S3 Standard ~$0.023/GB-month US East; S3 GET ~$0.0004/1K requests; S3 egress $0.09/GB to internet. Cite [AWS Athena Pricing](https://aws.amazon.com/athena/pricing/) and [AWS Glue Pricing](https://aws.amazon.com/glue/pricing/) as authoritative.
2. **Add a worked TCO example for a representative SaaS scale** (e.g., 100 TB stored, 50 TB scanned/month, 200 queries/day) comparing AWS Athena+Glue+S3 vs on-prem Trino+Iceberg+MinIO with explicit dollar figures including: storage ($/TB-mo), compute (per query or sustained), Glue Catalog API, S3 GET/LIST, FTE allocation, hardware amortization 5-yr, rack/power/cooling.
3. **Add concrete crossover heuristic with a dollar threshold**: "above ~X TB scanned/month sustained, self-hosted Trino+MinIO typically wins; below ~Y TB scanned/month or spiky/bursty, cloud Athena+Glue typically wins."

### MEDIUM
4. **Correct "storage nearly free on-prem" framing** — MinIO storage all-in (disks + replication/EC + hardware refresh + rack/power/cooling + ops) is non-trivial. Provide a $/TB-mo all-in on-prem storage estimate.
5. **Surface lift-and-shift constraints** — Athena requires Glue Catalog (or Lake Formation), not arbitrary Hive Metastore. The on-prem Iceberg + Hive Metastore stack requires metastore migration before Athena can query it.
6. **Inline glossary** for DPU (Data Processing Unit, 4 vCPU + 16 GB RAM in Glue context), DPU-hour, FTE (Full-Time Equivalent engineer), TCO, lift-and-shift, crossover point. Mirrors the long-standing `resources/22` glossary gap.

### LOW
7. **Reinforce prod_info.md on-prem-only hard constraint** — even when answering cost-comparison questions, frame the answer as "evaluation framework for the VP's question; deployment remains on-prem per current production policy." The iter362 answer did this correctly; resource should institutionalize the pattern.

## Iter363 judge probe targets (carried forward + new)

1. **Cost considerations cloud vs on-prem 2nd angle (NEW iter362)** — re-probe with a more concrete scenario (e.g., "we have 80 TB in MinIO and scan ~40 TB/month — give me a dollar comparison") to test whether iter363 teacher actions land specific pricing anchors and a worked dollar example.
2. **CDC tier 3rd angle** — iter362 Q1 4.50 landed cleanly with 2nd angle (post iter359 Q2 baseline 4.375); iter363+ could probe partition-scoped compaction per iter362 Q1 teacher action #2 if it lands.
3. **Trino federation glossary landing check** — 8th iteration probe pending.
4. **Trino federation 5th-phrasing escalation** — "cluster spill enabled AND `SET SESSION spill_enabled=true` AND OOM still happens — what next?"
5. **Query plan optimization 3rd angle** — TableScan cost reading OR Exchange operator interpretation.
6. **Connector-fit correctness re-probe** — query plan tuning against explicitly Iceberg-only stack.

## Sources verified via WebSearch

- [Amazon Athena Pricing — AWS](https://aws.amazon.com/athena/pricing/)
- [AWS Glue Pricing — AWS](https://aws.amazon.com/glue/pricing/)
- [Amazon Athena Pricing in 2026: Complete Cost Breakdown + Hidden Costs — Cloud Burn](https://cloudburn.io/blog/amazon-athena-pricing)
- [AWS Glue Pricing: How Much Does AWS Glue Really Cost in 2026 — Integrate.io](https://www.integrate.io/blog/aws-glue-pricing/)
- [AWS Athena Costs 2026: Best Cost Optimization Tips — Cloudvisor](https://cloudvisor.co/aws-athena-costs-2/)

---

## Iter 362 End-of-Iteration Summary

**Date**: 2026-05-29
**Phase**: EXTENDED
**Iteration average**: **4.1875 — PASS** (above 4.0 iteration bar; Q1 4.50 PASS + Q2 3.875 FAIL averaged across 2 questions)

### Per-question results

| Question | Topic | Score | Result | Notes |
|---|---|---|---|---|
| Q1 | CDC compaction cadence & ACID safety (Debezium-vs-`rewrite_data_files` concurrent writes) | 4.50 | STRONG PASS | iter361 judge probe target #1 cleared; CDC tier now durable 2-angle (iter359 Q2 4.375 baseline + iter362 Q1 4.50 re-probe) |
| Q2 | Cloud vs on-prem cost model (Athena+Glue+S3 lift-and-shift vs on-prem Trino+Iceberg+MinIO TCO) | 3.875 | FAIL | iter361 judge probe target #3 first probe; correct qualitative framing but missing 2026 AWS pricing anchors and concrete TCO example |

### Wins (cross-question)

1. **CDC tier officially durable** — Q1 4.50 paired with iter359 Q2 baseline 4.375 establishes 2-angle pass for the CDC sub-tier of the Postgres-to-Iceberg ingestion topic. Iter361 judge probe target #1 (CDC tier 2nd-angle re-probe) cleared. Topic running avg 4.522 across 133 questions, well above the 3.5 baseline.
2. **Honesty under resource uncertainty preserved** — Q2 correctly flagged that resources/ do not contain Athena/Glue pricing specifics and avoided fabricating dollar figures. Aligns with the iter354+ pattern of preferring honest "I don't have that data" over confident-wrong. The framing is qualitatively correct even where it lacks anchors.
3. **prod_info.md hard constraint correctly invoked in Q2** — on-prem-only deployment requirement surfaced even when answering a cost-comparison question, reinforcing the right environment-fit framing.
4. **No connector-fit factual error this iteration** — iter361's pattern of "diagnostically correct + one wrong operational property" did not recur. Q1 correctly named Iceberg-stack properties (`commit.retry.num-retries`, `write.distribution-mode`); Q2 correctly named AWS-stack categories (Athena per-TB, Glue per-DPU-h, S3 per-GB-mo) without confusing connector lanes.

### Critical gaps (cross-question)

1. **HIGH NEW iter362** — **Q2 missing 2026 AWS pricing anchors**: $5/TB Athena on-demand, $0.30/DPU-h Athena Provisioned Capacity (4 DPU min, 1-min billing, available since Feb 10, 2026), $0.44/DPU-h Glue ETL (Flex $0.29), $0.023/GB-mo S3 Standard, Glue Catalog 1M free then $1/100K, S3 GET ~$0.0004/1K, S3 egress $0.09/GB to internet. Without these the VP cannot build an evaluation memo. This is the single highest-priority teacher action for iter363.
2. **HIGH NEW iter362** — **Q2 no concrete worked TCO example** at a representative SaaS scale (e.g., 100 TB stored / 50 TB scanned-month / 200 queries-day). "Cloud cheaper at low volume, on-prem cheaper at high volume" is correct directionally but not actionable enough to support an evaluation. Need explicit dollar lines per axis and a clear crossover threshold ("above ~X TB scanned/month sustained, self-hosted wins").
3. **HIGH 8TH CONSECUTIVE ITERATION FLAGGED** — **inline glossary still not landed**: "snapshot isolation", "atomic commit", "optimistic concurrency", "equality delete", "position delete", "MoR/Merge-on-Read", "dangling delete", "CommitFailedException" missing from `resources/19-postgres-iceberg-ingestion.md` (Q1); "DPU", "DPU-hour", "FTE", "TCO", "crossover", "lift-and-shift" missing from cost-considerations resource (Q2). Beginner-clarity −1.0 deductions on BOTH answers trace back to this single gap. Longest-standing open issue; mirrors `resources/22` glossary gap that was flagged for 7 consecutive iterations on the Trino federation tier.
4. **MEDIUM** — **Q1 missing partition-scoped compaction (`where` clause on `rewrite_data_files`)** as the standard CDC-vs-compaction conflict mitigation pattern. Engineer at >100 ops/sec needs to scope compaction to cold partitions Debezium isn't actively writing to.
5. **MEDIUM** — **Q1 missing `rewrite_position_delete_files` procedure** in the nightly maintenance sequence. After `rewrite_data_files` on a CDC table, position deletes accumulate against the new data files and need their own compaction procedure. Sequence should be: `rewrite_data_files` → `rewrite_position_delete_files` → `expire_snapshots` → `remove_orphan_files`.
6. **MEDIUM** — **Q2 "storage nearly free on-prem" framing is misleading** — MinIO all-in $/TB-month (disks + replication/EC + hardware refresh + rack/power/cooling + ops) is non-trivial. Resource should provide an all-in on-prem storage estimate.
7. **MEDIUM** — **Q2 lift-and-shift constraints not surfaced** — Athena requires Glue Catalog (or Lake Formation), not arbitrary Hive Metastore. The on-prem Iceberg + Hive Metastore stack requires metastore migration before Athena can query it. Material constraint for the VP's evaluation.

### Topic running averages

- **Postgres-to-Iceberg ingestion**: 4.522 across 133 questions — PASSED, CDC sub-tier now durable 2-angle.
- **Cost considerations for analytical workloads at SaaS scale**: 4.354 across 6 questions — PASSED but topic average dropped 0.096 from 4.450 because iter362 Q2 landed below per-question 4.0 bar. Gained a 6th angle (cloud-vs-on-prem TCO) but lost ground on running avg.

### Iter363 teacher actions (priority-ordered)

**HIGH**
1. **Add 2026 AWS pricing anchors to cost-considerations resource**: Athena $5/TB on-demand; Athena Provisioned Capacity $0.30/DPU-h (4 DPU min, 1-min billing, since Feb 10, 2026); Glue ETL $0.44/DPU-h (Flex $0.29); Glue Data Catalog 1M free then $1/100K objects/accesses; S3 Standard ~$0.023/GB-mo US East; S3 GET ~$0.0004/1K requests; S3 egress $0.09/GB to internet. Cite [AWS Athena Pricing](https://aws.amazon.com/athena/pricing/) and [AWS Glue Pricing](https://aws.amazon.com/glue/pricing/) as authoritative.
2. **Add worked TCO example at representative SaaS scale** (e.g., 100 TB stored, 50 TB scanned/month, 200 queries/day) comparing AWS Athena+Glue+S3 vs on-prem Trino+Iceberg+MinIO with explicit dollar figures including: storage ($/TB-mo), compute (per query or sustained), Glue Catalog API, S3 GET/LIST, FTE allocation, hardware amortization 5-yr, rack/power/cooling.
3. **Add concrete crossover heuristic with dollar threshold**: "above ~X TB scanned/month sustained, self-hosted Trino+MinIO typically wins; below ~Y TB scanned/month or spiky/bursty, cloud Athena+Glue typically wins."
4. **Inline glossary at top of `resources/19-postgres-iceberg-ingestion.md`** for: "snapshot isolation", "atomic commit", "optimistic concurrency", "CommitFailedException", "equality delete", "position delete", "MoR / Merge-on-Read", "dangling delete", "compaction". 8TH CONSECUTIVE ITERATION FLAGGED across the glossary tier as a whole.
5. **Add partition-scoped compaction (`where` clause)** as Step 1 of CDC maintenance runbook: `CALL system.rewrite_data_files(table => 'hive.cdc.orders', where => 'event_date < current_date - 1', options => map('rewrite-all', 'true'))`.

**MEDIUM**
6. **Add `rewrite_position_delete_files`** to nightly maintenance sequence for CDC tables: `rewrite_data_files` → `rewrite_position_delete_files` → `expire_snapshots` → `remove_orphan_files`.
7. **Add CDC-specific table properties section**: `write.distribution-mode = 'hash'` on primary key column, `write.target-file-size-bytes = 134217728` (128MB) for high-rotation CDC tables.
8. **Add retry-budget-exhaustion callout for high-write CDC** at >100 ops/sec: raise `commit.retry.num-retries` to 10-20, raise `commit.retry.max-wait-ms` to 120000ms, use partition-scoped compaction.
9. **Correct "storage nearly free on-prem" framing** in cost-considerations resource — give all-in $/TB-mo MinIO estimate covering disks + EC + hardware refresh + rack/power/cooling + ops.
10. **Surface lift-and-shift constraints**: Athena requires Glue Catalog or Lake Formation, not arbitrary Hive Metastore.
11. **Inline glossary for cost-considerations resource**: DPU (Data Processing Unit, 4 vCPU + 16 GB RAM in Glue context), DPU-hour, FTE (Full-Time Equivalent engineer), TCO, lift-and-shift, crossover point.

**LOW**
12. **Add Debezium-Iceberg-sink-specific note** clarifying that Iceberg sink connector retry behavior is governed by Iceberg's `commit.retry.*` table-level properties; connector itself does not need additional retry configuration for compaction conflicts.
13. **Tie Spark CALL examples to production catalog** (`hive.<schema>.<table>` per Hive Metastore-backed Iceberg catalog in `prod_info.md`) and wrap in `SparkApplication` CR template for on-prem k8s Spark Operator.
14. **Reinforce prod_info.md on-prem-only hard constraint** institutionalization in cost-considerations resource — frame cost-comparison answers as "evaluation framework for VP's question; deployment remains on-prem per current production policy."

### Iter363 judge probe targets

1. **Cost considerations cloud vs on-prem 2nd angle (NEW iter362)** — re-probe with a more concrete scenario (e.g., "we have 80 TB in MinIO and scan ~40 TB/month — give me a dollar comparison") to test whether iter363 teacher actions land specific pricing anchors and worked dollar example. This is the highest-priority re-probe for iter363.
2. **CDC tier 3rd angle** — iter362 Q1 4.50 landed cleanly with 2nd angle (post iter359 Q2 baseline 4.375); iter363+ could probe partition-scoped compaction per iter362 Q1 teacher action #5 if it lands ("we tried hourly `rewrite_data_files` on our CDC table but it conflicts with Debezium writes — how do we scope compaction to cold partitions only?").
3. **Trino federation glossary landing check** — 8th iteration probe pending.
4. **Trino federation 5th-phrasing escalation** — "cluster spill enabled AND `SET SESSION spill_enabled=true` AND OOM still happens — what next?"
5. **Query plan optimization 3rd angle** — TableScan cost reading OR Exchange operator interpretation.
6. **Connector-fit correctness re-probe** — query plan tuning against explicitly Iceberg-only stack.

### Pattern observations

- **Iter362 broke the iter361 connector-fit factual-error pattern** — no "one wrong operational property per answer" defect this iteration. Q1 Iceberg-stack properties were correctly named; Q2 AWS-stack categories correctly named. Iter361 teacher action #2 (audit query-plan-optimization resource for connector-specific properties) appears to have landed for at least the iter362 prompts.
- **New first-probe pattern**: when judging a topic that has never been probed before in the loop (cost considerations cloud-vs-on-prem here), the weak responder reliably produces correct qualitative framing but lacks the specific 2026 dollar anchors needed for practical applicability. This is the same pattern observed when CDC tier was first probed in iter359 — first-probe answers tend to land at the 3.75-4.0 boundary on completeness and applicability until the resource is enriched with concrete numbers.
- **Glossary tier remains the single longest-standing open gap** — 8th consecutive iteration flagged. Across this iteration, BOTH answers took a −1.0 beginner-clarity deduction tracing back to missing inline definitions. The teacher should prioritize landing glossary blocks at the top of `resources/19` AND the cost-considerations resource before iter363 closes; the Trino-federation `resources/22` glossary tier has been flagged for 7 consecutive iterations on top of this.
- **Iteration-level consistency improving but ceiling pressure absent** — iter362 avg 4.1875 is above the 4.0 iteration bar but still has one answer at 3.875. The pattern across iter360-iter362 is 4.0625 → 4.000 → 4.1875 — slow upward drift in the 4.0-4.2 band, no breakouts to 4.5+ iteration avg. Topic-running-average gains will require either landing 4.5+ on both questions in the same iteration or shrinking the standard deviation across the 2 prompts.

