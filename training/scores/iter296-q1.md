# Iter 296 Q1 — Score

**Question topic**: TABLESAMPLE for fast exploratory queries on a 400M-row Iceberg events table; iteration workflow; approx functions; rollup as production fix.

**Production stack reference**: Trino 467 + Iceberg 1.5.2 + MinIO + k8s + dbt + Hive Metastore (on-prem). dbt explicitly supported per `prod_info.md`.

## Score table

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4 | Most claims verified. **Significant nuance error**: answer says BERNOULLI "of the remaining rows, keep roughly 5%... you scan ~7 days (~20M rows), then sample 5% (~1M rows). Query time drops from minutes to seconds." Per Trino docs, BERNOULLI scans **all** physical blocks then filters rows at runtime — it does NOT reduce I/O. The speedup actually comes almost entirely from the partition filter (7-day prune) plus downstream aggregation savings (less shuffle/GROUP-BY work after row-level filtering). The framing that BERNOULLI cuts scan from 20M → 1M overstates its effect; SYSTEM is the sampling method that can skip whole splits. `LIMIT` characterization is broadly correct (LIMIT doesn't prune partitions and on aggregations forces the full scan first), though Trino does push LIMIT through some plan shapes. `approx_distinct` ~2% / HyperLogLog is correct (actual standard error is ~2.3% by default; "~2% error, 10x–50x faster" is acceptable shorthand). `approx_percentile` uses T-Digest — verified. The conceptual fix (partition filter first, then sample, then approx functions, then validate full, then rollup) is sound and matches expected guidance. |
| Beginner clarity | 5 | Excellent scaffolding: leads with the LIMIT trap (correctly framed), then partition-filter + TABLESAMPLE pairing, explains BERNOULLI in plain English ("each row has a 5% independent chance"), table for choosing sample %, plain-English HyperLogLog/T-Digest pointers. Numbers (400M → 20M → 1M) make the scale intuitive. Iteration workflow (design / validate / production) named explicitly. No unexplained jargon. |
| Practical applicability | 5 | Copy-paste-ready SQL fits Trino 467 + Iceberg exactly. Uses real columns (`occurred_at`, `feature_name`, `user_id`, `load_time_ms`) the engineer can adapt. Concrete iteration workflow tells engineer what to do this afternoon. Rollup-table fix is the right longer-term answer and dbt-compatible per prod stack. Cost math (288 × 5-min scans → 1 nightly job) is exactly the kind of justification an engineer needs to defend the change. |
| Completeness | 5 | Covers: LIMIT trap, TABLESAMPLE BERNOULLI syntax + semantics, partition filter pairing, sample-size table, approx functions for cardinality/percentile, design→validate→production workflow, rollup as production fix. Could mention SYSTEM as the I/O-reducing alternative (and the BERNOULLI-doesn't-skip-blocks caveat above), but for the question asked — "can I sample so I iterate quickly" — the answer hits every must-cover concept. |

**Average**: (4 + 5 + 5 + 5) / 4 = **4.75 — PASS**

## Verification notes

WebSearch against trino.io confirmed:
- TABLESAMPLE: `BERNOULLI` scans all physical blocks and filters rows at runtime (no I/O reduction); `SYSTEM` divides table into logical segments and skips/includes whole segments. Source: trino.io/docs/current/sql/select.html. The answer's "scan ~7 days (~20M rows), then sample 5% (~1M rows)" implies BERNOULLI reduces scan volume, which is misleading — BERNOULLI's wall-clock win comes from less downstream work (aggregation, shuffle), not less I/O. The partition filter does the actual prune.
- `approx_distinct` is HyperLogLog with standard error ~2.3% default; user-supplied error parameter range [0.0040625, 0.26000]. Answer's "~2% error" is a slight rounding but acceptable. Source: trino.io/docs/current/functions/hyperloglog.html, trino.io/docs/current/functions/aggregate.html.
- `approx_percentile` backed by T-Digest — verified. Source: trino.io/docs/current/functions/aggregate.html.
- Iceberg partition pruning via WHERE on partitioned timestamp column — verified. Source: trino.io/docs/current/connector/iceberg.html, trino.io/blog/2023/04/11/date-predicates.html.
- LIMIT on Iceberg with GROUP BY: aggregations must complete the scan/group before LIMIT applies, so engineer's intuition that LIMIT will help is wrong — answer correctly calls this out.
- `CURRENT_DATE - INTERVAL '7' DAY` syntax — valid Trino SQL.
- Rollup-table pattern with dbt — fits prod_info.md stack.

## Topic mapping

Primary topic: **SQL query best practices for OLAP** (TABLESAMPLE, approx functions, LIMIT-doesn't-help pitfall, EXPLAIN/iteration workflow).

Secondary topics touched:
- Common analytical query patterns (aggregation + GROUP BY + ORDER BY)
- Query performance basics: partitioning, indexing strategy for analytics (partition filter as the actual scan-reducer)
- Schema design for analytics: denormalization (rollup table as pre-aggregation pattern)

## Rubric topic updates

**SQL query best practices for OLAP** — prior avg 4.613 across 10 questions (sum 46.13); new running avg (46.13 + 4.75) / 11 = 50.88 / 11 = **4.625 across 11 questions**. Status: **PASSED** (solidly above 3.5 and continuing to climb).

## Verdict

**4.75 — PASS**. Strong, well-structured, production-fit answer. One technical nuance to fix in resources: BERNOULLI does not reduce I/O scan — it reduces post-scan row processing. The speedup engineers will observe comes from (a) partition pruning via the WHERE clause and (b) reduced rows entering aggregation/shuffle, not from skipping data files. SYSTEM is the sampling method that can skip whole splits. Recommend a one-line clarification in the resource:

> "BERNOULLI still scans the whole filtered partition set; it speeds things up by reducing the rows that flow into the GROUP BY / shuffle, not by skipping files. If you need actual I/O reduction from sampling, use SYSTEM — but BERNOULLI is the right default for exploratory aggregations because it produces statistically clean samples row-by-row."

This is a refinement, not a correctness failure — the practical advice (use partition filter + TABLESAMPLE + approx functions for fast iteration, then rollup for production) remains correct and the engineer's queries will run faster as promised.
