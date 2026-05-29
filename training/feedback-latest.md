# Iter 373 Q1 — Judge Feedback (EXTENDED PHASE)

**Question**: "Can Trino on-prem read Iceberg tables stored in S3 buckets? And what's the performance hit vs local MinIO?"

**Topic probed**: Cost considerations cloud vs on-prem (AWS S3+Athena vs on-prem Trino+Iceberg+MinIO) — the recurring "still not probed" item from iter358/359/360 judge probe targets is FINALLY probed. Also touches the Trino Iceberg connector S3 file-system layer.

**Per-question score (target >= 4.0):**

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 3.5 | Storage-agnostic claim and S3/Athena pricing verified; MinIO ~$20/TB-month "all-in" is loose (raw is $2-4/TB per current WebSearch); crossover thresholds (<5 TB -> S3, >30 TB -> on-prem) are not grounded in any cited source and conflate workload-dependent variables. Athena pricing is technically irrelevant to "Trino reading S3" — it surfaces a different architecture (Athena) without flagging the swap. |
| Beginner clarity | 3.5 | "egress costs", "metadata fetch overhead", "Parquet 5-10x compressed" used without inline gloss. A SaaS engineer with no OLAP background gets the gist but not the mechanics. |
| Practical applicability | 4.0 | Correctly invokes the prod_info.md on-prem-only constraint as the bottom line — this is the right answer for THIS production environment, and the engineer immediately knows "you can't put Iceberg in public S3 from on-prem Trino." Rough crossover framework gives a coarse decision signal. |
| Completeness | 3.5 | Self-admitted no concrete latency numbers — which is EXACTLY the second half of the question ("what's the performance hit vs local MinIO?"). Also omits VPC/Direct Connect / S3 Express One Zone as latency-reduction options if the org ever does egress to S3, and omits the on-prem MinIO read path (POD-local, rack-local, or cross-DC) which is the actual baseline the comparison rests on. |
| **Average** | **3.625** | **FAIL** (below per-question 4.0 bar) |

---

## Judge verification via WebSearch

1. **Trino Iceberg connector storage-agnosticism — CORRECT.** Per [Iceberg connector — Trino 481 Documentation](https://trino.io/docs/current/connector/iceberg.html) and [S3 file system support — Trino 481 Documentation](https://trino.io/docs/current/object-storage/file-system-s3.html), the Iceberg connector supports both AWS S3 and MinIO through the native `fs.native-s3.enabled=true` file-system implementation. Endpoint configuration (`s3.endpoint`, `s3.path-style-access`) swaps the target between AWS and MinIO. The responder's "storage-agnostic, same S3 protocol" claim is accurate at the connector level.
2. **AWS S3 storage pricing — CORRECT.** Per [Amazon Athena Pricing](https://aws.amazon.com/athena/pricing/) and current S3 docs, S3 Standard is $0.023/GB/month for the first 50 TB. Athena is $5.00/TB scanned. The responder's numbers are accurate.
3. **Athena conflation — PROBLEMATIC.** The question asks specifically about **Trino on-prem** reading S3 Iceberg tables. The responder's "$5/TB scanned Athena" answers a DIFFERENT architecture (managed Athena query engine, not Trino-reading-S3-from-on-prem). Trino reading from S3 has no per-TB-scanned fee — costs are S3 GET request fees ($0.40/M requests) + egress ($0.09/GB out to on-prem k8s) + storage. The responder mixes two pricing models without flagging it.
4. **MinIO TCO claim — LOOSE.** Per [S3 Compatible Storage Cheapest Options 2026 — Ciro Cloud](https://cirocloud.com/artikel/s3-compatible-storage-cheapest-options-2026-cloud-cost-analysis), self-hosted MinIO on commodity hardware is $2-4/TB/month raw at >70% utilization. The responder's "~$20/TB-month all-in" is defensible only if amortizing hardware/ops/power/networking + ~0.5 FTE — which it does not state. The number is a black box. A reader cannot tell whether to trust it.
5. **Egress cost — CORRECT in direction.** AWS S3 egress is $0.09/GB out — the responder flags this as "real" which is the right framing for an on-prem k8s cluster that would pull S3 data over the public internet or via Direct Connect (which has its own per-GB fee).
6. **On-prem-only constraint correctly applied.** Per `prod_info.md` Section "Production environment (SaaS product and data team)": "Deployment: On-premises data center only — no public cloud. All services must run on-prem. Object storage: Bare-metal MinIO." The responder correctly closes with "this rules out public S3 in your prod stack" — exactly the right anchor.

---

## Gaps and deductions

### Technical accuracy (-1.5)
- **(a) Athena conflation.** The question is about **Trino reading S3**, not Athena. Mentioning "$5/TB scanned Athena" without saying "this is a different architecture, not what Trino-on-prem-reading-S3 would cost" is misleading. The Trino-reading-S3 cost stack is: S3 Standard storage + GET request fees + egress to on-prem cluster. The responder should have either (i) excluded Athena entirely or (ii) explicitly framed it as "if you instead used Athena managed, costs are X."
- **(b) Crossover thresholds unsourced.** "<5 TB/month S3 cheaper, >30 TB/month on-prem better" — neither threshold is grounded in any cited methodology, and real crossover depends on egress volume (read frequency), MinIO ops staffing, hardware purchase price, k8s node density, and whether read-heavy or write-heavy. Inventing precise numbers a SaaS engineer will quote in a planning doc is risky.
- **(c) MinIO TCO black box.** "$20/TB-month all-in" with no breakdown (hardware? ops? power? networking?) cannot be validated by the reader. Per current WebSearch, raw MinIO is $2-4/TB and the rest is FTE amortization — name the components.
- **(d) No mention of the actual question's pricing path.** The Trino-reading-S3-from-on-prem cost path is dominated by **egress**, not storage — that should have been the headline number ($0.09/GB out x monthly read volume). The responder mentions egress as a factor but does not put a number on it, which is the one number the engineer actually needs to plug into a spreadsheet.

### Beginner clarity (-1.5)
- "egress costs" — first mention has no inline gloss ("egress = data leaving AWS into your on-prem network, AWS charges you per GB").
- "metadata fetch overhead" — what metadata? Iceberg manifest files, snapshot.json, partition stats? The reader does not know.
- "Parquet compressed 5-10x" — Parquet not introduced. Even though the topic is loosely about formats, an OLAP-beginner reading this for the first time needs one line: "Parquet = the columnar file format Iceberg uses on disk; typically compresses analytical data 5-10x vs raw row format."

### Practical applicability (-1.0)
- The on-prem-only constraint anchor is exactly right and is the single best thing in the answer.
- Crossover thresholds give a coarse decision frame.
- BUT: the actual question — **"what's the performance hit?"** — is answered with "no specific latency numbers (honest limitation)." That is the question. A passable answer would have given an order-of-magnitude range (e.g., "local MinIO over rack-local network: ~1-5 ms object GET first-byte latency; public S3 over internet from on-prem: ~50-200 ms first-byte latency, ~10-50 ms over Direct Connect — so a query that does 1000 small manifest fetches goes from ~1-5 s on MinIO to ~50-200 s on public S3, which is why Iceberg's metadata caching matters").
- No mention of `iceberg.metadata-cache-enabled` or `hive.metastore-cache-ttl` as the Trino-side knobs that close the on-prem->S3 metadata-latency gap. These are the actionable levers for the actual question.
- No mention of Direct Connect / VPN as the network-path option that would make S3 from on-prem viable.

### Completeness (-1.5)
- Self-admitted no latency numbers — but the question literally is "what's the performance hit." This is the central deduction.
- No coverage of `iceberg.metadata-cache-enabled` and related Trino metadata caching knobs.
- No coverage of S3 Express One Zone (single-AZ, low-latency S3 tier) as the latency-targeted option for an organization that would consider running Trino on-prem against AWS-resident data.
- No coverage of Direct Connect / VPN as the egress-path option.
- No coverage of the on-prem MinIO baseline (pod-local vs rack-local vs cross-DC) which is the LEFT side of the comparison.
- No mention of the Trino S3 file-system properties (`fs.native-s3.enabled`, `s3.endpoint`, `s3.path-style-access`, `s3.region`) that the engineer would set differently for AWS S3 vs MinIO — these are the literal configuration deltas the question implies.

---

## Iter 374 teacher actions (priority-ordered)

1. **HIGH (correctness, completeness)** — Create or expand a "Cost & Performance: Trino on-prem reading AWS S3 vs local MinIO" sub-section. Must include:
   - **Cost model decomposition for Trino-reading-S3** (NOT Athena): storage ($0.023/GB-month) + GET requests ($0.40/M) + **egress ($0.09/GB out)** with a worked example: "100 TB scanned per month over Direct Connect at $0.02/GB = $2,000/month egress alone." Athena should appear only as a clearly-labeled alternative architecture, not as part of the Trino-reading-S3 cost stack.
   - **MinIO TCO decomposition**: $2-4/TB raw on commodity at >70% utilization (cite current 2026 WebSearch numbers), PLUS hardware refresh amortization, PLUS ~0.5 FTE ops at $120K/year amortized over PB-scale = ~$20/TB-all-in for a small fleet, dropping to ~$5/TB-all-in at multi-PB. Name the components so engineers can rebuild the math.
   - **Performance numbers** (the question's second half): local MinIO rack-local first-byte latency ~1-5 ms; public S3 from on-prem over internet ~50-200 ms; over Direct Connect ~10-50 ms; S3 Express One Zone ~1-10 ms (single-AZ premium tier). A typical Iceberg query plan touches metadata.json (1) + manifest list (1) + manifests (N, often 10-100) + data files (M, often 10-1000), so metadata GETs amplify latency.

2. **HIGH (clarity)** — Inline glosses on first mention:
   - "egress = data leaving AWS into your network, AWS charges per GB"
   - "Parquet = columnar file format Iceberg uses on disk; typically 5-10x compressed vs raw row format"
   - "metadata fetch = Trino reading Iceberg's snapshot/manifest list/manifests before reading data; each is a small object GET to S3/MinIO"

3. **MEDIUM (practical applicability)** — Add Trino-side latency-mitigation knobs explicitly:
   - `iceberg.metadata-cache-enabled` (default true) and `iceberg.metadata-cache-max-size`
   - `hive.metastore-cache-ttl` (if HMS is involved)
   - `fs.cache.enabled` for footer / manifest caching
   - These are the levers that close 50-200 ms of S3-from-on-prem latency back down to MinIO-local levels for repeat queries.

4. **MEDIUM (environment fit)** — Be explicit about the prod_info.md anchor:
   - The on-prem-only constraint means "you literally cannot put Iceberg data in AWS S3 and have your on-prem Trino cluster read it without external network egress and Direct Connect."
   - The architectural question for this prod environment is closer to "MinIO on-prem with native fs.native-s3.enabled connection" — that IS the production stack.
   - The cost comparison the engineer is asking about is a what-if exercise for either (a) future cloud migration or (b) hybrid burst capacity — frame it that way.

5. **LOW (carry-forward from prior iterations)** — Federation glossary expansion (CBO/BROADCAST/PARTITIONED/build/probe/left-deep) still pending in `resources/22`; HyperLogLog gloss on first mention still pending in `resources/07`/`resources/23`. Neither was probed this Q1.

---

## Iter 374 judge probe targets

1. **Cost-vs-performance re-probe at a different phrasing** (e.g., "Our finance team wants us to evaluate moving from on-prem MinIO to AWS S3 — what's the break-even point and what would the query latency look like?") — tests iter374 action #1 (cost decomposition + latency numbers).
2. **Trino metadata caching knobs** (e.g., "Our Iceberg queries do tons of small reads against MinIO — is there caching to make this faster?") — tests iter374 action #3 (metadata cache properties).
3. **S3 file-system configuration** (e.g., "How do I point Trino at our MinIO vs AWS S3? What properties change?") — tests iter374 action #4 (environment fit + native fs.native-s3.enabled).
4. **Carry-forward**: federation glossary (CBO/BROADCAST/PARTITIONED) — open since iter360.
5. **Carry-forward**: HyperLogLog gloss on first mention in `resources/07`/`resources/23` — open since iter372.

---

## Topic status update

- **Cost considerations for analytical workloads at SaaS scale**: 4.137 x 11 + 3.625 = 49.132 -> **4.094 across 12 questions** (still above 3.5 base pass threshold, but slipped 0.043 — first cloud-vs-on-prem angle for this topic, which had previously been general SaaS-cost framing. The cloud-vs-on-prem sub-angle is now demonstrated as the topic's weakest sub-angle and should be the next teacher focus.)
- No other topics meaningfully touched.

---

## Sources verified via WebSearch

- [Iceberg connector — Trino 481 Documentation](https://trino.io/docs/current/connector/iceberg.html) — connector supports AWS S3 + MinIO via S3 file system
- [S3 file system support — Trino 481 Documentation](https://trino.io/docs/current/object-storage/file-system-s3.html) — `fs.native-s3.enabled`, `s3.endpoint`, `s3.path-style-access` are the config knobs that swap between AWS S3 and MinIO
- [Amazon Athena Pricing](https://aws.amazon.com/athena/pricing/) — $5/TB scanned confirmed; this is the WRONG cost model for Trino-reading-S3-from-on-prem
- [Amazon Athena Pricing in 2026: Complete Cost Breakdown — Cloud Burn](https://cloudburn.io/blog/amazon-athena-pricing) — confirms 2026 Athena pricing structure
- [S3 Compatible Storage: Cheapest Options 2026 — Ciro Cloud](https://cirocloud.com/artikel/s3-compatible-storage-cheapest-options-2026-cloud-cost-analysis) — MinIO self-hosted $2-4/TB raw on commodity at >70% utilization
- [S3 Object Storage Cost Comparison: Cloud Vs Data Center — Stonefly](https://stonefly.com/blog/s3-object-storage-cost-comparison/) — egress is the dominant hidden cost; Direct Connect reduces but does not eliminate
- [Optimizing Data Storage and Querying with Trino, MinIO, and Apache Iceberg — Upsolver](https://www.upsolver.com/blog/trino-minio-iceberg) — local MinIO proximity reduces latency vs cloud S3

---

## Iter 373 End-of-Iteration Summary

**Iteration average: 4.1875 — PASS** (Q1 3.625 FAIL + Q2 4.75 STRONG PASS) / 2 = 4.1875

### Per-question recap

| Q | Topic | Score | Verdict | Per-dim pattern |
|---|---|---|---|---|
| Q1 | Cost considerations cloud vs on-prem (Trino on-prem reading S3 Iceberg vs local MinIO; performance hit) | **3.625** | **FAIL** | TA 3.5 / BC 3.5 / PA 4.0 / Comp 3.5 — uniform-low across all four dimensions, no single-dim collapse |
| Q2 | Multi-tenant analytics enterprise vs free-tier resource groups | **4.75** | **STRONG PASS** | (per per-question feedback above, omitted in this summary slot) |

### Iteration-level patterns

1. **Polarized iteration: std-dev 0.5625 between Q1 (3.625) and Q2 (4.75)** — sharpest within-iter polarization since iter370. Q2 STRONG PASS shows multi-tenant resource-group topic remains durably mature (joins SQL best practices + Iceberg schema-evolution in top-tier cluster); Q1 FAIL reveals that cost-cloud-vs-on-prem is now demonstrated as a structurally weaker sub-angle of the broader "cost considerations" topic.

2. **Topic regression on cost considerations: 4.137 -> 4.094 across 12 probes.** Still above 3.5 base threshold, but slipped 0.043 on this 12th probe. Importantly, this was the FIRST probe of the cloud-vs-on-prem sub-angle for the topic — prior 11 probes were general SaaS-cost framing — so the topic is not regressing on its strong sub-angles, it has acquired a new weak sub-angle that the teacher has not yet covered.

3. **Q1 failure mode is "answers a different question": Athena pricing surfaced in a Trino-reading-S3 cost question** without flagging that Athena is a different architecture. This is the second iteration in the extended phase where the responder conflated query-engine architectures (iter365 conflated Iceberg-storage-table-format with Trino-query-engine in a different direction). Suggests the resource files for cost coverage should be reorganized to label cost-stack-per-architecture explicitly: "Trino-on-prem reading S3" cost stack vs "Athena managed" cost stack vs "Trino-on-prem reading MinIO" cost stack.

4. **Q1 failure mode is "answers half the question": performance-hit half completely punted with "no specific latency numbers (honest limitation)".** This is the central deduction. Honest-limitation framing does not save the score when the question's second half is precisely what the gap is. Resources need order-of-magnitude latency anchors (rack-local MinIO ~1-5 ms, internet S3 ~50-200 ms, Direct Connect S3 ~10-50 ms, S3 Express One Zone ~1-10 ms) so the responder has numbers to cite.

5. **Q1 missed actionable Trino-side latency-mitigation knobs** (`iceberg.metadata-cache-enabled`, `iceberg.metadata-cache-max-size`, `hive.metastore-cache-ttl`, `fs.cache.enabled`). These are the levers a SaaS engineer would actually turn — their absence makes the answer abstract rather than actionable.

6. **Q1 missed S3 file-system configuration deltas** (`fs.native-s3.enabled`, `s3.endpoint`, `s3.path-style-access`, `s3.region`) that are the literal configuration changes between AWS S3 and MinIO. The Trino 481 docs make these properties explicit and they are the most direct answer to "how does the connector treat them differently."

7. **Carry-forward debt still pending**: federation glossary (CBO/BROADCAST/PARTITIONED/build/probe/left-deep) in `resources/22` open since iter360, HyperLogLog gloss on first mention in `resources/07`/`resources/23` open since iter372. Neither was probed this iteration so neither manifested — both remain latent risks.

### Iter360-373 trajectory

iter360 4.0625 -> iter361 4.000 -> iter362 4.1875 -> iter363 4.0625 -> iter364 4.00 -> iter365 4.25 -> iter366 3.8125 -> iter367 4.625 -> iter368 4.375 -> iter369 4.47 -> iter370 3.98 FAIL -> iter371 4.5625 PASS -> iter372 4.75 STRONG PASS -> iter373 4.1875 PASS. Trend: extended-phase oscillation between 3.8 and 4.75 with topic-by-topic stratification — mature topics (SQL best practices, Iceberg schema evolution, multi-tenant resource groups) hit 4.5-4.75 reliably; newly-probed sub-angles of older topics (cost cloud-vs-on-prem) regress to 3.6-4.0 on first contact.

### Iter 374 priority for teacher

1. **HIGH** — Create or expand cost+performance section on Trino-on-prem reading AWS S3 vs local MinIO with: (a) cost stack decomposition per architecture (storage + GET requests + egress for Trino-reading-S3; raw + hardware + ops FTE for MinIO TCO), (b) order-of-magnitude latency anchors per network path, (c) worked egress example.
2. **HIGH** — Inline glosses for egress, Parquet, metadata fetch on first mention.
3. **MEDIUM** — Add Trino-side latency-mitigation knobs (`iceberg.metadata-cache-enabled`, `iceberg.metadata-cache-max-size`, `hive.metastore-cache-ttl`, `fs.cache.enabled`).
4. **MEDIUM** — Add Trino S3 file-system configuration deltas (`fs.native-s3.enabled`, `s3.endpoint`, `s3.path-style-access`, `s3.region`) with AWS-vs-MinIO worked config blocks.
5. **MEDIUM** — Reinforce prod_info.md on-prem-only anchor: cost comparison is a what-if for future cloud migration or hybrid burst — not the production stack itself.
6. **LOW carry-forward** — federation glossary (resources/22) and HyperLogLog gloss (resources/07, resources/23).

### Iter 374 judge probe targets

1. **Cost-vs-performance re-probe at different phrasing** (e.g., "Finance wants us to evaluate moving from on-prem MinIO to AWS S3 — what's the break-even and what would query latency look like?") — durability test for iter374 action #1.
2. **Trino metadata caching knobs** ("Our Iceberg queries do tons of small reads against MinIO — is there caching to make this faster?") — tests iter374 action #3.
3. **Trino S3 file-system configuration** ("How do I point Trino at our MinIO vs AWS S3? What properties change?") — tests iter374 action #4.
4. **Carry-forward**: federation glossary (CBO/BROADCAST/PARTITIONED) — open since iter360.
5. **Carry-forward**: HyperLogLog gloss on first mention — open since iter372.
