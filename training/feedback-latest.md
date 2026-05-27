# Feedback — Iter 290 (Extended phase)

Date: 2026-05-27
Topic: SQL query best practices for OLAP — second iteration (Q1 FAIL, Q2 PASS perfect)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | date_trunc vs DATE()/CAST() partition pruning — which forms break pruning in Trino 467? | **3.00** | FAIL |
| Q2 | JOIN ordering: broadcast vs partitioned join; CBO + ANALYZE; join_distribution_type; EXPLAIN signals | **5.00** | PASS |

**Iter 290 average: 4.00**

**Topic update**: SQL query best practices for OLAP: 4.19/2 → **4.095/4 questions** (PASSED — still above 3.5 threshold but Q1 failures are pulling down the avg)

---

## Critical error (Q1) — recurring optimizer rule pattern

**The mistake**: The corrected resource 23 section 6 over-rotated after the iter289 DATE()/CAST() fix. It marked `date_trunc('day', ts)` as "truly non-invertible" and put it in the "Functions that definitely break pruning" table. This is wrong.

**The truth**: Trino 467 has TWO optimizer unwrap rules for timestamp predicates:
- `UnwrapCastInComparison` (PR #13567, 2022): handles `CAST(ts AS DATE)` and `DATE(ts)` comparisons
- `UnwrapDateTruncInComparison` (PR #14011, 2022): handles `date_trunc('day', ts) = DATE '...'` comparisons

Both rewrite the predicate to an equivalent TIMESTAMP range before partition pruning. The Trino blog post "Just the right time date predicates with Iceberg" (trino.io/blog/2023/04/11/date-predicates.html) explicitly confirms this for BOTH forms.

**What actually breaks pruning** (no unwrap rule exists):
- `year(ts) = 2026` — non-monotonic, can't be expressed as a single range
- `month(ts) = 5` — non-monotonic
- `day_of_week(ts) = 3` — non-monotonic
- `hour(ts) = 14` — non-monotonic
- `LOWER(col)`, `SUBSTR(col, ...)` — not invertible

**Edge cases where even DATE()/CAST()/date_trunc may fail**:
- `timestamp with time zone` columns — unwrap has known TZ normalization limitations
- `unwrap_casts` session property = false
- Complex nested expressions

**Resources fixed**: Both resource 10 and resource 23 section 6 have been corrected to accurately document both optimizer rules. The resource correction pattern: iter289 fixed DATE(), resource over-corrected to break date_trunc; iter290 now fixed date_trunc back to correct.

---

## What worked

### Q1
1. DATE(x) = CAST(x AS DATE) aliasing and UnwrapCastInComparison — correct
2. TIMESTAMP range as the safe defensive production form — correct
3. `constraint on [event_at]` in TableScan as pruning signal — correct
4. `timestamp with time zone` edge case — correctly flagged

### Q2 (perfect score)
1. Broadcast = smaller table as hash table in every worker's memory — correct
2. Partitioned join = shuffle both tables by key — correct
3. CBO needs NDV from ANALYZE (not just row count) — correct
4. `join_distribution_type` values (AUTOMATIC/BROADCAST/PARTITIONED) — correct
5. `Join[BROADCAST]` in EXPLAIN = broadcast active — correct
6. `Estimates: {rows: ?}` = CBO guessing — correct
7. ANALYZE TABLE → Puffin files → NDV — correct
8. Postgres-vs-Trino mental model (B-tree vs file-based) — excellent framing

---

## Resource fixes applied

- **Resource 23 section 6** — removed date_trunc from "definitely breaks pruning"; added UnwrapDateTruncInComparison explanation; updated "functions Trino CAN unwrap" list; kept TIMESTAMP range as defensive production form
- **Resource 10 lines ~888-894** — corrected back to accurate state: date_trunc('day', ts) IS handled by UnwrapDateTruncInComparison

---

## Suggested iter291 angles

1. **SQL OLAP best practices — final re-test on partition pruning** (Q1 scored 3.00; the correct answer should distinguish: DATE()/CAST()/date_trunc('day', ts) all work; year()/month()/day_of_week() do NOT; TIMESTAMP range is the explicit production form)

2. **SQL OLAP best practices — LIMIT behavior** (doesn't reduce scan cost; TABLESAMPLE BERNOULLI alternative)

3. **SQL OLAP best practices — CTEs and subquery reuse** (Trino materializes some CTEs; running same subquery twice in OLTP habit is expensive in OLAP)

4. **New topic exploration** — if SQL OLAP is stable, start testing other weak areas from rubric
