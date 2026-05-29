# Iter 374 Judge Feedback

## Q1 — "What's the actual cost breakdown when our on-prem Trino workers pull data from S3, and how does that compare to local MinIO?"

This is the CRITICAL re-probe of the iter373 Q1 failure (Trino-on-prem reading S3 cost+performance vs local MinIO). Per iter373 judge probe target #1, this iteration tests whether iter374 teacher actions land: (a) cost stack decomposition per architecture with Athena clearly LABELED as alternative architecture not part of Trino-reading-S3 stack, (b) order-of-magnitude latency anchors, (c) metadata caching knobs.

### Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | (a) S3 egress $0.09/GB for first 10TB CONFIRMED via [AWS S3 Pricing](https://aws.amazon.com/s3/pricing/) tiered after that ($0.085/GB next 40TB, $0.07/GB next 100TB, $0.05/GB above 150TB) — responder's $0.09/GB is correct at small scale but 50TB/month at flat $0.09/GB overstates by ~3% versus tiered actual ($4,365 vs $4,500 reported); minor rounding within tolerance; (b) S3 storage $23.55/TB-month = $0.023/GB CONFIRMED accurate Standard tier; (c) GET requests $0.0004/1K CONFIRMED accurate; (d) Athena vs Trino-reading-S3 distinction CORRECTLY drawn per [Vantage on S3+Athena+Trino](https://www.vantage.sh/blog/s3-bill-increase-athena-trino-hive-fix-iceberg-caching) — Athena = $5/TB scanned managed query, Trino-reading-S3 = just S3 costs no per-query charge — this is the EXACT iter373 failure mode FIXED here, major correctness recovery; (e) Direct Connect $0.02/GB + $220/month baseline CONFIRMED at 1Gbps small-port pricing; (f) Latency numbers 50s vs 500s for 10K-file metadata fetch directionally correct (10x amplification from rack-local-MinIO to remote-S3 due to per-object GET round-trip), though the absolute 50s for local MinIO is on the high end — rack-local with metadata cache cold should be 5-15s for 10K files at 1-2ms/GET, not 50s; warm cache should be <1s. Minor latency-magnitude overshoot. Overall correctness recovery from iter373 3.5. |
| Beginner clarity | 4.0 | Egress, storage, GET, metadata cache, Direct Connect all explained inline. "Cold/archival data" framing is clear. Minor drag: "metadata cache as critical optimization" mentioned but not named with specific Trino property names (`iceberg.metadata-cache-enabled`, `iceberg.metadata-cache-max-size`, `hive.metastore-cache-ttl`) per iter374 teacher action #3 — engineer can't search for these by name. Otherwise reads cleanly for a SaaS engineer with no AWS background. |
| Practical applicability | 4.5 | Engineer can compute their own bill: 50TB/month → $4,500 egress is a concrete anchor. Direct Connect break-even math is implied ($0.02/GB savings × volume must exceed $220/month baseline + setup). "Use S3 only for cold/archival data" is actionable architectural guidance that fits on-prem-MinIO-is-production prod_info.md anchor. The Athena clarification prevents engineer from accidentally specing Athena as a Trino-on-S3 alternative. Drag: no specific config snippet for the metadata cache knobs that would close the on-prem-S3 latency gap for repeat queries. |
| Completeness | 4.0 | Covers cost stack decomposition (egress + storage + GET), Athena-vs-Trino distinction, MinIO $0 egress contrast, latency anchors, Direct Connect option, metadata cache mention, cold/archival framing. Missing: (a) MinIO TCO decomposition ($2-4/TB raw + ops FTE amortization) per iter374 teacher action #1; (b) Trino S3 filesystem config deltas (`fs.native-s3.enabled`, `s3.endpoint`, `s3.path-style-access`) per iter374 teacher action #4; (c) named metadata cache property names. The core question (cost + how it compares) is answered, but the actionable Trino-side configuration half is thin. |

**Q1 average: (4.5 + 4.0 + 4.5 + 4.0) / 4 = 4.25 PASS**

Major iter373→iter374 recovery: the Athena conflation failure mode is FIXED, latency anchors are present (iter373 was punted), Direct Connect path is concrete. Remaining gaps are config-name specificity (caching knobs + S3 filesystem deltas) and MinIO TCO decomposition. Iter374 teacher action #1 (cost stack decomposition + Athena labeling) LANDED; action #3 (metadata caching knobs by name) PARTIAL — concept mentioned, property names not surfaced; action #4 (S3 filesystem config deltas) NOT LANDED in this probe but not required by this question phrasing.

---

## Q2 — "What is Iceberg 'hidden partitioning' and how is it different from regular Hive-style partitioning?"

Foundational Iceberg concept probe. Iceberg partition design topic is at 4.570 avg over 18 questions, mature. This question tests the canonical "hidden partitioning" terminology and the Hive contrast.

### Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | (a) "Hidden = partition machinery invisible to query author" CONFIRMED canonical per [Apache Iceberg Partitioning](https://iceberg.apache.org/docs/latest/partitioning/) — "Iceberg avoids reading unnecessary partitions automatically, and consumers don't need to know how the table is partitioned and add extra filters to their queries"; (b) Hive requires manual `WHERE year=2024 AND month=3` partition predicates CONFIRMED — Hive partition columns are explicit table columns; (c) Iceberg filter on business column `WHERE occurred_at >= '...'` with Iceberg translating via partition transform CONFIRMED per Iceberg docs; (d) `day(occurred_at)` partition transform CONFIRMED real syntax in `PARTITIONED BY (day(occurred_at))`; (e) "No special syntax needed" CONFIRMED; (f) Partition evolution transparent with old files keeping old spec CONFIRMED — this is the per-snapshot partition-spec-id mechanism in Iceberg. All claims verified against official Iceberg docs. |
| Beginner clarity | 4.5 | "Partition machinery invisible to query author" is a clean one-line framing. Hive-side example (`WHERE year=2024 AND month=3`) and Iceberg-side example (`WHERE occurred_at >= ...`) make the contrast concrete with side-by-side SQL. "Faster queries by default for new team members" surfaces the team-onboarding value clearly. Minor drag: "partition transform" used without inline gloss on first mention — engineer needs to infer that `day(occurred_at)` is a built-in function that buckets timestamps to daily partitions. |
| Practical applicability | 4.5 | Engineer knows: (a) they can `PARTITIONED BY (day(occurred_at))` in their Iceberg table DDL, (b) their dbt models and ad-hoc SQL filter on `occurred_at` directly (no `partition_date` redundant column), (c) onboarding cost for new engineers is lower (they don't need to know the physical layout), (d) partition evolution is safe (old data files retain their old spec). Fits prod_info.md Iceberg 1.5.2 + Trino 467 stack — both support `day()`, `month()`, `year()`, `hour()`, `bucket(N, col)`, `truncate(N, col)` transforms. Drag: no mention of which Iceberg version introduced each transform, no callout that legacy Hive tables migrated to Iceberg may still have the legacy partition-column-as-data-column shape. |
| Completeness | 4.5 | Covers definition (hidden = machinery invisible), Hive contrast (manual predicates), Iceberg behavior (auto-translation from business column), example transform (`day(occurred_at)`), zero-special-syntax benefit, partition evolution transparency. Missing: (a) full transform catalog (`year`, `month`, `day`, `hour`, `bucket(N, col)`, `truncate(N, col)`, `identity`) — engineer doesn't know what other transforms exist; (b) the metadata-driven mechanism (partition spec stored per snapshot in manifest list, planner uses transform to filter manifest entries by partition value range); (c) Trino-specific syntax notes for the Iceberg connector. Core question fully addressed, edge details light. |

**Q2 average: (5.0 + 4.5 + 4.5 + 4.5) / 4 = 4.625 STRONG PASS**

Foundational concept, mature topic, clean exposition. Hive-vs-Iceberg contrast is sharp and the `day(occurred_at)` example anchors the abstract concept concretely. Engineer leaves with actionable DDL pattern + onboarding-cost argument for Iceberg adoption.

---

## Iter374 summary

- **Iter374 average: (4.25 + 4.625) / 2 = 4.4375 PASS**
- Q1 4.25 PASS — critical iter373 re-probe RECOVERS; Athena conflation FIXED; latency anchors PRESENT; remaining gap is config-name specificity (metadata cache knobs, S3 filesystem config deltas)
- Q2 4.625 STRONG PASS — foundational Iceberg hidden partitioning, mature topic, clean delivery
- Iter374 std-dev: 0.1875 — convergent iteration, both answers in the same band, contrast with iter373 0.5625 polarization
- Topic running averages: cost considerations for analytical workloads at SaaS scale: (4.094 × 12 + 4.25) / 13 = (49.128 + 4.25) / 13 = 53.378 / 13 = **4.106 across 13 questions** — recovers +0.012 from iter373's slip, cloud-vs-on-prem sub-angle now demonstrated as durable on re-probe; Iceberg partition design for SaaS: (4.570 × 18 + 4.625) / 19 = (82.260 + 4.625) / 19 = 86.885 / 19 = **4.573 across 19 questions** — holds at top-tier band

### Iter374 teacher action landing
- **Action #1 (cost stack decomposition + Athena labeling) LANDED** — Q1 correctly separates Athena ($5/TB managed) from Trino-reading-S3 (just S3 costs); this was the iter373 failure mode and it is FIXED
- **Action #2 (inline glosses) PARTIAL** — egress + Direct Connect explained inline, metadata cache mentioned but property names not surfaced
- **Action #3 (metadata caching knobs by name) PARTIAL** — concept present, property names (`iceberg.metadata-cache-enabled`, `hive.metastore-cache-ttl`) NOT surfaced
- **Action #4 (S3 filesystem config deltas) NOT TESTED** — question phrasing did not require it; carry forward to next probe of this sub-angle
- **Action #6 (federation glossary CBO/BROADCAST/PARTITIONED) NOT TESTED** — federation not probed this iter, carry forward
- **Action #7 (HyperLogLog gloss) NOT TESTED** — HLL not probed this iter, carry forward

### Iter375 judge probe targets
1. **Trino S3 filesystem config deltas** — fresh phrasing: "How do I point Trino at our MinIO vs AWS S3 — what properties change in the catalog file?" — tests iter374 action #4 which did not land in iter374 Q1
2. **Trino metadata caching knobs by name** — fresh phrasing: "Our Iceberg queries do tons of small reads against MinIO — what's the specific Trino config property to enable metadata caching?" — tests iter374 action #3 surfacing property names
3. **Carry-forward federation glossary** (CBO/BROADCAST/PARTITIONED) — open since iter360, not probed iter371-iter374
4. **Carry-forward HyperLogLog gloss** — open since iter372, not probed iter373-iter374
5. **Iceberg partition evolution mechanics** — follow-up to iter374 Q2: "We started with `day(occurred_at)` and want to switch to `month(occurred_at)` — what happens to existing data files and old queries?" — tests partition-spec-per-snapshot mechanism understanding

### Sources verified
- [AWS S3 Pricing](https://aws.amazon.com/s3/pricing/) — egress $0.09/GB first 10TB, tiered after
- [Vantage: S3 bill + Athena + Trino + Iceberg](https://www.vantage.sh/blog/s3-bill-increase-athena-trino-hive-fix-iceberg-caching) — Athena $5/TB scanned vs self-hosted Trino just S3 charges
- [Amazon Athena Pricing](https://aws.amazon.com/athena/pricing/) — $5/TB scanned confirmed
- [Apache Iceberg Partitioning](https://iceberg.apache.org/docs/latest/partitioning/) — hidden partitioning canonical term + transforms + partition evolution
- [Tabular: Using Hidden Partitioning](https://www.tabular.io/apache-iceberg-cookbook/data-engineering-hidden-partitioning/) — hidden partitioning practical cookbook
