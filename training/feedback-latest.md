# Judge Feedback — Iter 379 (EXTENDED PHASE)

**Date**: 2026-05-30
**Overall**: **4.8125 STRONG PASS** (combined Q1 + Q2 average; both questions cleared 4.5)

---

## Per-question scores

### Q1 — ANALYZE TABLE on Iceberg for Trino CBO

**Score: 4.8125 / 5.0 — STRONG PASS**

| Dimension | Score |
|---|---|
| Technical accuracy | 5.0 |
| Beginner clarity | 4.5 |
| Practical applicability | 5.0 |
| Completeness | 4.75 |

**What the responder got right**:
- Correctly framed ANALYZE as a **full scan** (column-targeted reduces the columns read but is not sampling) — this is the canonical correct framing and corrects a common misconception.
- **Puffin sidecar files with NDV sketches** — exact tool name, exact storage format, exact statistic type. Verified vs [Puffin Spec — Apache Iceberg](https://iceberg.apache.org/puffin-spec/) and [Trino PR #13636 — Analyze Iceberg tables](https://github.com/trinodb/trino/pull/13636).
- **3-layer pruning model**: Layer 2 = automatic file skipping via manifest min/max (no ANALYZE needed), Layer 3 = CBO join reordering via NDV (needs ANALYZE). This is the exactly correct mental model that separates "what Iceberg gives you for free" from "what ANALYZE buys you."
- **`drop_extended_stats` footgun before column-targeted re-runs** — this is the documented Trino-Iceberg gotcha (drop_extended_stats wipes ALL Puffin stats, so a subsequent `ANALYZE WITH (columns = ARRAY[...])` leaves the un-listed columns without NDV). Critical production warning.
- **Cadence**: weekly or after major ingest — production-realistic guidance.
- **Verification**: `SHOW STATS FOR <table>` — correct Trino syntax.

**Gaps (minor, BC and Comp)**:
- "Layer 2/Layer 3" framing assumes the engineer has read prior resources on the cumulative pruning model — a one-line inline gloss ("Puffin = sidecar file format that stores stats next to your Iceberg data files") would close BC for a true newcomer.
- Could mention: (a) Puffin stores **Theta Sketch / probabilistic NDV** at very large cardinalities (not always exact); (b) explicit `ANALYZE table WITH (columns = ARRAY['col_a','col_b'])` syntax; (c) Puffin stats are tied to a specific snapshot ID (interaction with concurrent writes).

---

### Q2 — EU data residency with on-prem Iceberg

**Score: 4.8125 / 5.0 — STRONG PASS**

| Dimension | Score |
|---|---|
| Technical accuracy | 5.0 |
| Beginner clarity | 4.5 |
| Practical applicability | 5.0 |
| Completeness | 4.75 |

**What the responder got right**:
- **Led with the most important correction**: Iceberg partitioning is metadata, not physical location. A partition spec controls file layout within a storage namespace; it does NOT pin bytes to a specific geographic region. This is the #1 misconception engineers have and the responder addressed it first.
- **Separate MinIO + separate Iceberg catalog** is the correct production architecture for residency. Verified vs [GDPR Compliance with Apache Iceberg — A Practical Guide (Ryft)](https://www.ryft.io/blog/gdpr-compliance-with-apache-iceberg-a-practical-guide) and [Forward Data Conference — GDPR-compliant Iceberg Lakehouse](https://www.forward-data-conference.com/en/programme/talks/how-to-create-a-gdpr-compliant-iceberg-lakehouse).
- **Model 1 = namespace per compliance tier** within each catalog — concrete architectural pattern the engineer can implement.
- **One Trino cluster querying both MinIO via two catalog configs** — correct Trino multi-catalog mechanism (`etc/catalog/iceberg_eu.properties`, `etc/catalog/iceberg_us.properties`).
- **Trino views + OPA for query-time enforcement** — production-fit per prod_info.md (Trino + OPA is the documented authorization backend). The responder correctly did NOT attempt to write specific OPA policies (those belong in the external governance document).
- **Ingestion routing by customer residency flag** — correct write-time pattern that closes the loop on residency from end to end.

**Gaps (minor, BC and Comp)**:
- "Compliance tier", "residency flag", and "Model 1" assume governance vocabulary; a one-line definition of "data residency" (data must physically live in a specific geographic region, not merely be labeled as such) would close BC.
- Could mention: (a) **cross-catalog join warning** — joining EU + non-EU tables in one Trino query may itself constitute a "data transfer" under GDPR Chapter V (engineer should consult legal); (b) **backup/snapshot residency** — Iceberg snapshot expiry + orphan-file cleanup logs may cross regions if the maintenance job runs in the wrong location; (c) **Right to Be Forgotten** DELETE workflow must run independently in each catalog.

---

## Pattern observations across both questions

1. **TA at ceiling**: Both questions scored 5.0 on technical accuracy. The responder gave exact tool names (`Puffin`, `SHOW STATS FOR`, `drop_extended_stats`), exact architectural patterns (two catalogs, namespace-per-tier), and exact production-fit constraints (on-prem MinIO, OPA, Trino 467 + Iceberg 1.5.2). Zero factual errors detected by WebSearch verification.

2. **PA at ceiling**: Both questions scored 5.0 on practical applicability. The engineer has actionable next steps in both cases:
   - Q1: Run ANALYZE on schedule, use SHOW STATS to verify, avoid the drop_extended_stats sequence.
   - Q2: Stand up a second MinIO in EU, mount two Iceberg catalogs in Trino, namespace per compliance tier, route ingestion by residency flag, enforce at query time via OPA + views.

3. **BC drag is the recurring weak dimension**: Both questions lost 0.5 on Beginner Clarity due to jargon used without inline gloss ("Layer 2/Layer 3", "Puffin", "NDV", "CBO", "compliance tier", "residency flag", "Model 1"). The terms are USED in context, but a true beginner with zero OLAP background would not immediately parse them. This is a small, consistent gap that has appeared in the last several iterations.

4. **Comp drag is minor depth on edge cases**: Both questions lost 0.25 on Completeness due to missing one or two edge-case nuances (Theta Sketch probabilistic nature on Q1; cross-catalog join + backup residency on Q2). Core question is fully answered; only depth on adjacent concerns is missing.

5. **Production-stack fit**: Both answers are correctly scoped to the on-prem Trino 467 + Iceberg 1.5.2 + HMS + MinIO + k8s + JWT/OPA stack from prod_info.md. Q2 in particular correctly deferred specific OPA policy details to the external governance document (matching prod_info.md guidance).

---

## Teacher actions for iter 380

1. **LOW (BC inline gloss carry-forward)**: Add one-line inline glosses on next pass:
   - "Puffin = Iceberg sidecar file format that stores table-level statistics (NDV sketches, theta sketches) next to your data files."
   - "NDV (Number of Distinct Values) = an estimate of how many unique values are in a column, used by the query planner to decide join order."
   - "CBO (Cost-Based Optimizer) = the Trino planner module that uses statistics to pick the cheapest query plan."
   - "Data residency = a legal requirement that data physically lives in a specific geographic region (not just labeled as such)."
   - "Compliance tier = a category of data that has different regulatory requirements (e.g., EU PII vs US business metrics)."

2. **LOW (Comp depth carry-forward Q1)**: Add to ANALYZE TABLE / Puffin / CBO resources:
   - Theta Sketch is probabilistic at very large cardinalities (typical default ~16K buckets, ~2% error).
   - `ANALYZE table WITH (columns = ARRAY['col_a','col_b'])` syntax for column-targeted re-runs.
   - Puffin stats are tied to a specific snapshot ID; concurrent writes invalidate stats for the new snapshot until the next ANALYZE.

3. **LOW (Comp depth carry-forward Q2)**: Add to data residency / multi-region Iceberg resources:
   - Cross-catalog join may constitute a "data transfer" under GDPR Chapter V — flag for legal review.
   - Snapshot expiry + orphan-file cleanup must run from a maintenance job that has the same residency as the data it touches.
   - Right to Be Forgotten DELETE workflow runs independently per catalog (no single SQL DELETE spans regions).

4. **LOW (carry-forward unprobed open items from iter378+)**:
   - 7-day rolling average per tenant in Trino — RANGE BETWEEN INTERVAL '6' DAY PRECEDING (window function 3rd angle still unprobed).
   - Bloom filter low-cardinality side (country_code 200 distinct values WHERE — correct answer NO, still unprobed as 3rd angle).
   - `write.target-file-size-bytes=512MB` via Spark DDL but Trino writes 200MB files — Trino-vs-Spark write property split (iter378 carry-forward).
   - `write.distribution-mode=hash` on bucket-partitioned Iceberg — Spark vs Trino split + skew caveat (iter378 carry-forward).
   - EXPLAIN ANALYZE warning carry-forward iter376.
   - Federation glossary carry-forward iter370+.
   - HyperLogLog inline gloss open since iter372.
   - MinIO TCO open since iter374.

---

## Topic score updates

- **Trino CBO / ANALYZE TABLE / Puffin statistics / NDV / join ordering** (per-topic threshold 4.5): running avg 4.810/5 → **4.8104/6** (added iter379 Q1 at 4.8125). PASSED at raised threshold sustained.
- **Multi-tenant analytics: isolating customer data in SaaS**: running avg 4.449/144 → **4.4515/145** (added iter379 Q2 at 4.8125). PASSED sustained.

---

## Iter 370–379 trajectory

4.625 → 4.375 → 4.47 → 3.98 FAIL → 4.5625 → 4.75 → 4.1875 → 4.4375 → 4.40625 → 4.5625 → 3.25 FAIL → 4.71875 → **4.8125 STRONG PASS**

The recovery from iter377 (3.25 FAIL) is now sustained across iter378 (4.71875) and iter379 (4.8125). Iter379 is the highest score in the last 10 iterations, with both per-question scores at the same high water mark (4.8125 each). Two consecutive strong PASS iterations indicate the resource base is stable for the topics being probed. No critical actions needed; only minor BC inline-gloss and Comp depth refinements remain.
