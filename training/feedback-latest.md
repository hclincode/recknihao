# Feedback — Iter 293 (Extended phase)

Date: 2026-05-27
Topics: SQL query best practices for OLAP + Analytical query patterns — window functions and columnar SELECT * cost

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | Window functions vs GROUP BY for running totals; spilling; pre-aggregation pattern | **5.00** | PASS |
| Q2 | SELECT * cost in columnar storage: Parquet column chunks, three pruning layers, Physical Input | **5.00** | PASS |

**Iter 293 average: 5.00 — PASS** ✓

**Topic updates**:
- SQL query best practices for OLAP: 4.516/8 → **4.613/10 questions** (PASSED — strong above 4.5)
- Analytical query patterns on Iceberg+Trino: 4.550/5 → **4.625/6 questions** (PASSED — reinforced)

---

## What worked

### Q1 — Window functions for running totals (5.0)
1. Correct window function syntax with frame clause — `SUM(...) OVER (PARTITION BY ... ORDER BY ... ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` — verified
2. Why GROUP BY can't do running totals (collapses rows) — clear explanation
3. Self-join O(n²) cost — good concrete math (1M events → 1 trillion comparisons)
4. `spill-enabled=true` + `spill_window_operator` session property — verified
5. `EXCEEDED_LOCAL_MEMORY_LIMIT` error code — correct
6. ANALYZE TABLE for CBO stats — correct
7. Pre-aggregation nightly dbt model as production pattern — excellent practical guidance

### Q2 — SELECT * columnar cost (5.0)
1. Parquet column chunks as contiguous byte ranges — correct
2. Trino reads only SELECT-listed column chunks — verified
3. Three-layer pruning (manifest → row-group → column chunk) — correct order and explanation
4. Postgres-vs-Trino contrast — excellent framing for the audience
5. Physical Input in EXPLAIN ANALYZE as the measurement tool — verified
6. Rollup table / dbt model as the production mitigation — fits stack

**Minor note (not score-affecting)**: Q2 short answer said "25x more I/O" but the worked example computes ~16.7x (50 columns / 3 = 16.7). The teacher may want to make these consistent in a future resource pass.

---

## No resource fixes needed

Both answers were factually clean. Resources are accurate.

---

## Suggested iter294 angles

1. **Continue SQL OLAP best practices** — `TABLESAMPLE BERNOULLI` for cheap exploration; or `approx_percentile` use cases (already covered, could reinforce with different angle)

2. **New topic breadth** — consider testing "Multi-tenant analytics" or "Real-time vs batch" which haven't had recent coverage

3. **Schema design for analytics** (4.50/2 questions) — still at minimum question count; more angles would solidify it
