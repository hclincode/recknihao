# Iter 302 Q2 Judge Score

## Topic
SQL query best practices for OLAP

## Scores
| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | 4.75 |

## Pass/Fail
PASS (threshold: 3.5)

## Technical accuracy verification

Claims checked against Trino official docs and engineering blogs:

1. **`approx_distinct` uses HyperLogLog** — CORRECT. Trino docs explicitly state HyperLogLog with 32-bit buckets, switching between sparse and dense representations.

2. **Default standard error ~2.3% (0.023)** — CORRECT. Trino docs: "produces a standard error of 2.3%." The answer's framing of "68% within ±2.3%, 95% within ±4.6%" is a reasonable interpretation of standard deviation under approximately normal error.

3. **Accuracy parameter range 0.0040 – 0.26** — CORRECT. Actual documented range is [0.0040625, 0.26000]; the answer's rounding is acceptable.

4. **"All `user_id` values shuffle to a single coordinator node"** — PARTIALLY INCORRECT. For a query with `GROUP BY event_date`, Trino's distinct aggregation does NOT send all values to a single coordinator. Distinct aggregation strategies (MARK_DISTINCT, PRE_AGGREGATE, SINGLE_STEP, SPLIT_TO_SUBQUERIES) all distribute work across workers, typically partitioning by the GROUP BY key (event_date) so each worker handles a subset of days. The real bottleneck is the multiple re-shuffles required by MarkDistinct and per-group memory pressure when groups have very large NDV, not "one node holds all distinct values." This is the most consequential technical error in the answer — it overstates the centralization. However, the practical guidance (use `approx_distinct` or rollup) still applies because the per-group dedup and shuffle overhead does explode at 12-month scale.

5. **`EXPLAIN (TYPE DISTRIBUTED)` valid in Trino** — CORRECT. It is the recommended replacement for `EXPLAIN (TYPE LOGICAL)`, which is deprecated.

6. **Production stack fit (Trino 467 + Iceberg + dbt + MinIO + on-prem k8s)** — Excellent fit. The rollup table example uses `iceberg.analytics.*`, mentions dbt and Spark, no cloud-only services referenced.

## What worked
- Clear three-pronged structure: exact-vs-approximate, rollup pattern, partition-pruning verification.
- Concrete validation SQL (compute pct_error on 5-10 sample days before deploying) — exactly what an engineer needs.
- The decision matrix (internal ops / customer dashboards / billing / compliance) is excellent practical guidance for "is it trustworthy enough for customers?".
- Correctly flags non-determinism of `approx_distinct` as the real customer-facing concern.
- The hybrid pattern (UNION rollup with `approx_distinct` for today-so-far) is the production-grade answer.
- Mentions the "break into monthly sub-queries and UNION" fallback for stubborn exact-required cases.
- Includes ANALYZE TABLE follow-up.
- Numbers are concrete and grounded: "10–50x faster", "365 rows → milliseconds", "3–4 minutes to under 1 second."

## What was wrong or missing
- **The "single coordinator node" explanation oversimplifies/misrepresents the distributed execution.** Trino partitions by GROUP BY key; the bottleneck for `COUNT(DISTINCT user_id) GROUP BY event_date` is the multiple re-shuffles of MarkDistinct + per-group memory when individual groups have high cardinality, not centralization to one node. A more accurate framing: "exact distinct requires shuffling data by the distinct column (user_id) for deduplication, often layered on top of the GROUP BY shuffle by event_date, which is why a 12-month query multiplies the shuffle/memory cost."
- No mention of `approx_set` / `merge` / `cardinality` for sketch reuse — relevant for the rollup pattern (you can store HLL sketches per day and union them at query time, getting both speed and the ability to compute multi-day distinct without re-scanning raw events). This was flagged as a gap on iter289 Q2 too.
- No mention of the Trino session property `distinct_aggregations_strategy` which can be tuned for this exact scenario.
- No mention of `EXPLAIN ANALYZE` (only `EXPLAIN`) for verifying that the rewritten query is actually faster at runtime with Physical Input bytes.

The "single coordinator node" framing is a long-standing simplification that gets the right answer (use approx_distinct or rollup) for the wrong reason. Docking 1 point on technical accuracy for it.

## Suggested topic score update
Old: 4.626 / 11 questions (sum = 50.886)
New avg if this scores 4.75: (50.886 + 4.75) / 12 = 55.636 / 12 = **4.636 across 12 questions**
Status: PASSED (above 3.5 threshold; still trending up)
