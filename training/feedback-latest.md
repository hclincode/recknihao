# Feedback — Iter 292 (Extended phase)

Date: 2026-05-27
Topic: SQL query best practices for OLAP — fourth iteration (Q1 PASS perfect, Q2 PASS perfect)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | CTEs in Trino: inlined not materialized; N references = N executions; CASE WHEN fix; CTAS for cross-query | **5.00** | PASS |
| Q2 | HAVING vs WHERE: correct for aggregates, bad for raw columns; engineer's query is already right | **5.00** | PASS |

**Iter 292 average: 5.00 — PASS** ✓

**Topic update**: SQL query best practices for OLAP: 4.355/6 → **4.516/8 questions** (PASSED — strongly above 4.0, recovering well from early oscillation)

---

## What worked

### Q1 — CTE inlining (5.0)
1. CTEs inlined (not materialized) in Trino — correctly stated
2. N references = N executions — correct
3. No CTE materialization hint in Trino 467 — correct, no invented property
4. CASE WHEN inside aggregates as single-pass fix — canonical and correct
5. CTAS as cross-query materialization workaround — correct for Trino 467 + Iceberg stack
6. Predicate pushdown through single-use inlined CTEs — correct
7. EXPLAIN self-diagnosis recipe — practical

### Q2 — HAVING vs WHERE (5.0)
1. WHERE runs before aggregation, HAVING after — correct
2. Engineer's specific query already correct — directly answered the question
3. BAD: HAVING on raw column (tenant_id IN ...) — correct illustration of the actual trap
4. HAVING on COUNT/SUM = mandatory, no alternative — correct
5. EXPLAIN ANALYZE + Physical Input redirect for slow query diagnosis — excellent

---

## No errors — no teacher action required

Both answers passed with perfect scores. Resources are accurate and the responder is performing well on SQL OLAP best practices.

---

## Topic state

SQL query best practices for OLAP is now at **4.516/8 questions** — well above the 3.5 threshold and tracking above 4.5 over the last 4 iterations. The topic has recovered from the early oscillation on partition pruning optimizer rules.

---

## Suggested iter293 angles

1. **Continue SQL OLAP best practices** — remaining areas: SELECT * columnar overhead (concrete bytes example), or window functions vs GROUP BY for running totals

2. **Cross-topic** — test a different resource area to ensure coverage breadth; consider testing "Multi-tenant analytics" or "Real-time vs batch analytics" which haven't been tested recently

3. **New angle from the weaker topics** — schema design for analytics hasn't been tested in many iterations; could be worth a re-check
