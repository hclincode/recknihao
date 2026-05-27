# Iter 291 Q2 — Judge Score

**Question**: How can I estimate how much data a Trino query will scan against a large Iceberg table (5 TB, partitioned by day) before running it? User knows about EXPLAIN but wants help interpreting it for estimating scan cost.

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All four approaches are technically sound. `$files` metadata table with `file_size_in_bytes` is correct (verified against Trino 481 / Iceberg connector docs). `Physical Input` in `EXPLAIN ANALYZE` is real (and was even improved in release 477). Bare `EXPLAIN` does NOT show Physical Input — correct. The `date_trunc('day', occurred_at) = DATE '...'` claim correctly references Trino's `UnwrapDateTruncInComparison` rule (PR #14011, in 467). The unsafe list (`year()`, `month()`, complex arithmetic) is accurate. One nit: `constraint on [occurred_at]` is the right signal but predicates pushed via `Constraint.predicate` (vs `Constraint.summary`) don't always prune — the answer's binary "constraint = good / ScanFilterProject = bad" is a slight simplification, but a reasonable one for an introductory decision flow. |
| Beginner clarity | 5 | The four-approach ladder (mental math → metadata → EXPLAIN → EXPLAIN ANALYZE sample) is exactly the right teaching scaffold. Each approach has copy-paste SQL. Numeric example (14 GB/day raw, 1.4–2.8 GB/day compressed, 42–84 GB for 30 days) makes the math concrete. Decision flow at the end is unambiguous. |
| Practical applicability | 5 | The engineer gets a working SQL query against `$files` they can run today, a verification step via EXPLAIN, and a 1-day sample technique with extrapolation. The "when your estimate jumps to full 5 TB" table is directly actionable — they can scan their own WHERE clauses against it. The 10–30s expected query time on a healthy Trino cluster sets the right cost expectation. |
| Completeness | 5 | Covers all four approaches from cheapest (mental math) to most precise (EXPLAIN ANALYZE 1-day sample). Addresses the EXPLAIN-vs-EXPLAIN-ANALYZE distinction the engineer specifically asked about. Calls out pruning failure modes. Decision flow ties it together. Could mention `system.runtime.queries` post-hoc or the `cardinality` cost estimates from bare EXPLAIN, but those are nice-to-haves, not gaps. |

**Average**: **5.0** — PASS

## Verification notes

- `$files` metadata table with `file_size_in_bytes`, `record_count`, `partition`, `file_path` — confirmed in Trino 481 Iceberg connector docs and the deep-dive blog.
- `Physical Input: X GB` in `EXPLAIN ANALYZE` — confirmed; release 477 specifically improved physical input accounting accuracy.
- `date_trunc('day', ts) = DATE '...'` enabling pruning via `UnwrapDateTruncInComparison` — confirmed (PR #14011), and the rule applies to date/timestamp partition columns in Iceberg.
- `DATE(occurred_at) = DATE '...'` claim: this is a cast, which Trino also unwraps for date/timestamp comparisons — answer is correct.
- The `constraint on [occurred_at]` signal: real and useful, but with a subtle caveat (predicates in `Constraint.predicate` rather than `Constraint.summary` may not prune even when they appear). Not a scoring deduction at this level of detail.

## Rubric topic mapping

- **Query performance basics: partitioning, indexing strategy for analytics** — already PASSED at 4.594 / 4q. This answer reinforces it.
- **SQL query best practices for OLAP** — already PASSED at 4.095 / 4q. Strongly relevant (EXPLAIN verification, type-safe predicates, avoiding pushdown-breaking patterns). Update below.
- **Analytical query patterns on Iceberg+Trino** — tangentially relevant; not the primary topic.
