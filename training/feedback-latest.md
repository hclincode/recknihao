# Feedback — Iter 289 (Extended phase)

Date: 2026-05-27
Topic: SQL query best practices for OLAP — first iteration of new topic (Q1 PASS barely, Q2 PASS strong)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | Partition pruning: DATE()/CAST() handling in Trino 467, UnwrapCastInComparison, TIMESTAMP range as defensive best practice | **3.50** | PASS (barely) |
| Q2 | approx_distinct() HyperLogLog, COUNT DISTINCT shuffle cost, EXPLAIN vs EXPLAIN ANALYZE, Physical Input, CPU/Scheduled timing | **4.88** | PASS |

**Iter 289 average: 4.19 — PASS** ✓

**Topic update**: SQL query best practices for OLAP: NEW TOPIC → 4.19/2 questions → **PASSED** (≥3.5 threshold with 2 angles)

---

## What worked

### Q1 — Partition pruning function wrapping (3.50)
1. TIMESTAMP range rewrite (`>= TIMESTAMP '...' AND < TIMESTAMP '...'`) — correct and is the recommended form
2. `constraint on [event_time]` in TableScan vs `ScanFilterProject` distinction — correct EXPLAIN signals
3. Planning-time vs runtime framing for partition pruning — conceptually accurate
4. EXPLAIN verification recommendation — correct and practical

### Q2 — approx_distinct and EXPLAIN (4.88)
1. HyperLogLog backing, 2.3% default error, syntax `approx_distinct(col, 0.01)` — all verified
2. COUNT DISTINCT shuffle cost explanation (RemoteExchange moving all distinct values) — correct
3. Three EXPLAIN forms clearly delineated (bare EXPLAIN, TYPE DISTRIBUTED, EXPLAIN ANALYZE) — correct
4. Physical Input field in EXPLAIN ANALYZE — verified
5. CPU vs Scheduled vs Blocked timing interpretation — correct (I/O-bound vs compute-bound)
6. Pre-run EXPLAIN checklist — directly actionable

---

## Critical error (Q1)

**DATE(x) is CAST(x AS DATE) in Trino — and Trino 467 CAN unwrap this.**

The answer stated `DATE(event_time)` is "exactly why" Trino was doing a full scan. This is wrong for Trino 467. `DATE(x)` is documented as an alias for `CAST(x AS DATE)`. Trino's `UnwrapCastInComparison` optimizer rule (PR #13567, shipped 2022, trino.io/blog/2023/04/11/date-predicates.html) handles this case and does enable partition pruning in most cases.

**What actually breaks pruning** (truly non-invertible):
- `date_trunc('day', col)` — non-invertible, many timestamps map to same truncated value
- `year(col)`, `month(col)`, `day_of_week(col)`, `hour(col)` — non-monotonic for ranges
- `LOWER(col)`, `SUBSTR(col, ...)` etc.
- **Edge case**: `timestamp with time zone` — UnwrapCastInComparison has known limitations here; EXPLAIN verification extra important

**The fix in resource 23** (section 6) has been applied: added UnwrapCastInComparison explanation, "Trino CAN unwrap" vs "definitely breaks pruning" distinction, kept TIMESTAMP range as defensive best practice, added timestamp with time zone caveat.

---

## Resource fixes applied

- **Resource 23 section 6** — corrected DATE()/CAST() vs date_trunc distinction; added UnwrapCastInComparison explanation; added edge case for timestamp with time zone

---

## Suggested iter290 angles

1. **SQL OLAP best practices — re-test partition pruning** (Q1 scored only 3.50 — need to solidify this angle with correct DATE()/CAST() nuance)

2. **SQL OLAP best practices — JOIN ordering and CBO** — put smaller table as build side; when to trust CBO vs force join_distribution_type; how ANALYZE TABLE affects join planning

3. **SQL OLAP best practices — CTEs vs subqueries vs multiple queries** — WITH clauses; Trino materializes some CTEs; when to push into one query vs split

4. **SQL OLAP best practices — LIMIT behavior** — reinforce that LIMIT doesn't reduce scan cost; TABLESAMPLE BERNOULLI alternative

5. **Trino federation re-test** — topic is PASSED but solidifying at 4.511/251; any new angle to keep it high
