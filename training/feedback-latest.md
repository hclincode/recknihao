# Feedback — Iter 302 (Extended phase)

Date: 2026-05-27
Topics: Denormalize plan attributes vs federated join (Q1) + COUNT(DISTINCT) at scale / approx_distinct (Q2)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | Denormalize plan_tier into events; star schema; SCD Type 2; as-of join; no backfill on plan upgrade | **5.00** | PASS |
| Q2 | COUNT DISTINCT shuffle cost; approx_distinct (HyperLogLog 2.3% error); nightly rollup; UNION hybrid | **4.75** | PASS |

**Iter 302 average: 4.875 — PASS** ✓

**Topic updates**:
- Schema design for analytics: 4.50/4 → **4.60/5 questions** (PASSED — improved)
- SQL query best practices for OLAP: 4.626/11 → **4.636/12 questions** (PASSED — stable)

---

## Resource fixes applied (teacher already corrected these)

None for Q1 — all claims correct.

### Resources 23 and 07: COUNT DISTINCT mechanism (fix before iter303)

The Q2 answer's mechanism explanation was wrong: "all user_id values shuffle to a single coordinator node." This is inaccurate for Trino.

**Correct explanation:** Trino distributes distinct aggregation across workers via MarkDistinct strategies (MARK_DISTINCT, PRE_AGGREGATE, SINGLE_STEP, SPLIT_TO_SUBQUERIES). For `COUNT(DISTINCT user_id) GROUP BY event_date`, Trino partitions work by `event_date` across workers. The real bottleneck is:
1. Multi-shuffle overhead (GROUP BY shuffle + distinct column shuffle layered on top)
2. Per-group memory pressure when groups have high NDV
3. Multiple re-shuffles when multiple distinct expressions appear in one query

**Fix in resources 23 and 07:**
- Remove or correct any "all values to one node" / "coordinator collects all" phrasing
- Add accurate MarkDistinct mechanism description (multi-shuffle, not centralization)
- Add `approx_set(user_id)` + `merge()` + `cardinality()` HLL sketch reuse pattern (pre-aggregate sketches per day, then merge for rolling WAU/MAU windows without re-scanning raw data)
- Add `distinct_aggregations_strategy` session property as a tuning knob before reaching for approx_distinct
- Recommend `EXPLAIN ANALYZE` (not just `EXPLAIN`) to verify bytes-read reduction after optimization

---

## What worked

### Q1 — Denormalization (5.00)
1. "No backfill when plans change" — stated clearly and correctly with reasoning (historical value is the right value)
2. Three-way comparison: federated join / denormalize at ingest / as-of join for current state — systematic
3. PySpark `broadcast()` join pattern for enrichment at ingest — verified correct
4. SCD Type 2 with valid_from/valid_to for as-of joins — correct pattern
5. "Don't denormalize display_name" — practical gotcha preventing future backfill debt
6. Iceberg ALTER TABLE ADD COLUMN is metadata-only — verified correct
7. On-prem stack alignment — all code uses correct Spark + Iceberg + Trino 467 syntax

### Q2 — approx_distinct (4.75)
1. Three-pronged structure: exact-vs-approx / rollup / partition pruning verification
2. Validation SQL to measure real error on production data — excellent
3. Decision matrix: internal ops / customer trend / billing / compliance — crisp and defensible
4. Non-determinism caveat (page-load-to-page-load variance) correctly identified as the real customer concern
5. Hybrid UNION pattern (rollup historical + approx_distinct for today) — production-grade
6. approx_distinct accuracy parameter (0.01 for tighter bounds) — verified correct against Trino docs
7. All numbers correct: 2.3% default standard error, [0.0040, 0.26] range

---

## Suggested iter303 angles

1. **HLL sketch reuse** — `approx_set` + `merge` + `cardinality` for rolling WAU/MAU without re-scanning raw events (directly addresses gap flagged in Q2 judge feedback)
2. **Iceberg time-travel** — `FOR TIMESTAMP AS OF` / `FOR VERSION AS OF`; debugging production data issues; snapshot retention floor
3. **Approximate functions deeper** — `approx_percentile` for p95/p99 latency metrics; when percentile approximation is appropriate
4. **dbt snapshot vs SCD Type 2 manually** — now that resource 13 covers dbt incremental, cover dbt snapshot strategy for dimension tables
