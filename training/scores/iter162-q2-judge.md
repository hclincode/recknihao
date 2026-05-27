# Iter 162 Q2 — Judge Report

## Question
"We have our raw event data in Iceberg and our customer account settings sitting in Postgres. We run queries pretty often that join those two sources together to slice usage metrics by account tier or plan type. Someone on my team said Trino can query both at once without moving the Postgres data anywhere. That sounds great, but our joins feel slow and I am not sure if we should just copy the Postgres tables into Iceberg instead. How do I decide whether to keep running these cross-source joins in Trino or whether it is worth the hassle of ingesting the Postgres data into Iceberg?"

## Topic touched
- Trino federation / cross-source connectors (PostgreSQL connector, predicate pushdown, cross-catalog join limits, when to federate vs ingest) — elevated pass threshold 4.5
- Tangentially: Postgres-to-Iceberg ingestion (full refresh vs incremental for small dim tables)

---

## Verification of key technical claims

1. **"The join itself always runs on Trino workers — cannot be pushed down to Postgres" (for cross-catalog joins)** — CORRECT.
   - Trino's PostgreSQL connector supports cost-based join pushdown only for joins between two tables in the same PostgreSQL catalog. Cross-catalog joins (Postgres ↔ Iceberg) cannot be pushed down to either source; both sides are materialized to Trino workers, then joined.
   - The answer's framing ("Trino can optimize how much data flows across the network before the join happens") accurately captures the mental model.

2. **Dynamic filtering: build side hash → IN-list pushed to probe-side scan** — CORRECT and well-explained.
   - The Trino dynamic filtering docs confirm: when one side of a join is small, Trino builds a filter at runtime from the actual join key values seen on the build side, then pushes that filter to the probe side's scan to skip files/partitions/rows.
   - The "IN-list with thousands of values" framing is a reasonable beginner-friendly simplification. (Technically Trino's DF can also be represented as min/max ranges or Bloom-style summaries, but for a beginner, the IN-list intuition is fine and not misleading.)
   - Iceberg scan honoring DF for file-level pruning is correct.

3. **`EXPLAIN (TYPE DISTRIBUTED)` + look for `dynamicFilters = {...}` on `ScanFilterProject`** — CORRECT.
   - Per Trino docs, the `ScanFilterProject` operator displays `dynamicFilters = {column = #df_<id>}` when DF is pushed to the connector scan.
   - Minor nuance: `EXPLAIN ANALYZE` actually shows runtime DF statistics (e.g., `dynamicFilterSplitsProcessed`), whereas `EXPLAIN (TYPE DISTRIBUTED)` shows only the *plan*. The answer's recommendation is still valid (plan-level DF assignment confirms it would fire), but a stronger verification would also mention `EXPLAIN ANALYZE` for runtime stats. Not a blocking error.

4. **Decision matrix (federate for one-off, ingest for repeated dashboards)** — CORRECT and a recognized industry pattern.
   - Federation is the well-documented choice for ad-hoc exploration and live freshness; ingestion is the standard choice for repeated dashboards, multi-table joins, and load isolation. The answer matches this widely-accepted heuristic.

5. **Full refresh for small dimension tables (under 100K rows), incremental for large** — CORRECT.
   - The 100K row cutoff is a reasonable rule of thumb. For very small reference tables, nightly full overwrite via `createOrReplace()` is operationally simpler than maintaining watermarks/MERGE logic. Incremental with `updated_at` watermark is the canonical approach for larger dimensions.
   - Caveat: full refresh also breaks Iceberg time-travel continuity (new snapshot replaces all rows), but that's typically acceptable for dimension tables.

6. **"Once in Iceberg, join becomes intra-catalog and can leverage broadcast join optimization — likely 10–100x faster"** — DIRECTIONALLY CORRECT.
   - Speedup estimate is plausible for typical SaaS workloads. The 10–100x range is on the optimistic side; observed speedups depend on Iceberg file layout, statistics, and Postgres connection contention. The earlier iter161-q2 question reported a real 20-min → 30-sec (40x) speedup, so the range is grounded.

### Minor accuracy nits
- "Trino creates an IN-list filter (`user_id IN (id1, id2, ..., id5000)`)" — slight simplification; Trino's internal DF representation is more flexible than a literal IN-list (can use min/max ranges, hash sets). The user-visible effect is the same, so this is acceptable for the audience.
- `EXPLAIN (TYPE DISTRIBUTED)` recommendation is good but `EXPLAIN ANALYZE` would let the engineer see *whether DF actually fired and how many splits were skipped* at runtime — worth mentioning as a follow-up.
- The "Decision flowchart" question "Is the account settings table small (<1M rows)?" uses 1M as the threshold, but the narrative just above says 100K is the cutoff for "small dimension table." Mild inconsistency — won't confuse most readers but a careful one will notice.
- "Real-time Postgres querying is only necessary if the account tier changes several times per minute" — fine framing, though understates that some compliance/audit use cases also demand live source-of-truth reads.

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | All core mechanics are correct: cross-catalog join execution on Trino workers, DF build→probe pattern, EXPLAIN verification approach, federate-vs-ingest decision matrix, full vs incremental refresh. Minor nits: IN-list oversimplification, missing `EXPLAIN ANALYZE` mention for runtime DF stats, the 100K vs 1M threshold inconsistency in the flowchart. |
| Beginner clarity | 5 | Excellent structure: opens with the right framing (the join always runs on Trino — the optimization is data reduction), then walks through DF with a concrete IN-list example, then a decision flowchart, then a concrete recommendation. No unexplained jargon. The "5000 unique account IDs" example makes DF tangible. |
| Practical applicability | 5 | The engineer can act on this immediately: (a) run `EXPLAIN (TYPE DISTRIBUTED)` to check DF, (b) if DF missing → ingest, (c) for the account settings dim specifically, full refresh nightly. Fits the on-prem Trino 467 + Iceberg + Spark + Hive Metastore stack from prod_info.md exactly. The "hidden cost of ingestion" section (Spark job, watermark column, monitoring) reflects real operational reality. |
| Completeness | 5 | Addresses all parts of the question: (a) how does cross-catalog join actually work (workers, DF), (b) when to federate vs ingest (matrix + flowchart), (c) the specific cost of ingestion (Spark job, watermark, monitoring), (d) a concrete recommendation backed by reasoning, (e) a verification step before committing to ingestion. Bonus: covers the "small dim table = full refresh" simplification. |

**Weighted average** = (4.5 × 2 + 5 + 5 + 5) / 5 = (9.0 + 15) / 5 = **4.80**

## Pass/Fail
**PASS** (4.80 ≥ 4.5 elevated threshold for this topic).

---

## Verdict on topic status
- Before iter162-q2: Trino federation topic had avg **4.333** across 3 questions, status NEEDS WORK (elevated threshold 4.5).
- Updated: avg = (4.333 × 3 + 4.80) / 4 = (13.0 + 4.80) / 4 = 17.80 / 4 = **4.450** across 4 questions.
- Status: Still **NEEDS WORK** (4.450 < 4.5 elevated threshold) — but very close. One more passing answer (≥4.5) should clear the bar.

## Recommendations for teacher
1. **Tighten DF representation language**: in resources/22 (or wherever federation is covered), state that DF can be IN-list, min/max range, or Bloom-style — IN-list is the common beginner-friendly intuition but not the only form.
2. **Add `EXPLAIN ANALYZE` for runtime DF verification**: pair the plan-level `dynamicFilters = {...}` check with `EXPLAIN ANALYZE` showing `dynamicFilterSplitsProcessed` / `Input: X rows (Y skipped)`. The current answer recommends plan-level check only.
3. **Document the small-dim full-refresh pattern** explicitly with a `createOrReplace()` snippet — the answer alludes to it but doesn't show the Spark code.
4. **Note Postgres connection pool budget shared with Trino** (carried over from iter11 feedback) — on-prem k8s deployments often have a finite Postgres connection budget; large federated queries can starve other consumers. The answer didn't mention this; worth adding to the "hidden cost of federation" side of the matrix.
