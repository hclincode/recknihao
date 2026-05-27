# Feedback — Iter 291 (Extended phase)

Date: 2026-05-27
Topic: SQL query best practices for OLAP — third iteration (Q1 PASS, Q2 PASS perfect)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | Partition pruning: which date functions are safe (DATE()/CAST(), date_trunc) vs which break pruning (year(), month(), day_of_week()) | **4.75** | PASS |
| Q2 | Estimating scan cost before running: $files metadata, EXPLAIN ANALYZE 1-day sample, Physical Input field | **5.00** | PASS |

**Iter 291 average: 4.875 — PASS** ✓

**Topic update**: SQL query best practices for OLAP: 4.095/4 → **4.355/6 questions** (PASSED — recovering strongly after iter290 Q1 failures)

---

## What worked

### Q1 — Partition pruning function breakdown (4.75)
1. Both optimizer rules correctly stated: UnwrapCastInComparison (DATE()/CAST()) and UnwrapDateTruncInComparison (date_trunc) — correct after 2 iterations of oscillation
2. Non-monotonic functions correctly identified as the truly broken class: year(), month(), day_of_week(), hour() — no unwrap rule
3. TIMESTAMP range as guaranteed production form — correct
4. EXPLAIN verification guidance — correct
5. Fixes for non-monotonic functions (explicit ranges or precomputed columns) — practical

### Q2 — Scan cost estimation (5.0)
1. Four-approach ladder (mental math → $files → EXPLAIN → EXPLAIN ANALYZE sample) — excellent teaching structure
2. `$files` metadata table with `file_size_in_bytes` — verified correct
3. `Physical Input: X GB` in EXPLAIN ANALYZE — correct field
4. 1-day sample + extrapolation technique — directly actionable
5. "When your estimate jumps to full 5 TB" table — immediately useful
6. Numeric examples (14 GB/day raw, 1.4-2.8 GB compressed, 42-84 GB for 30 days) — concrete

---

## Minor error (Q1) — already fixed

**Claim**: `unwrap_casts` session property = false disables the unwrap rules.
**Reality**: This property was removed in Trino 364 (PR #9550). The rules are always-on in Trino 467 — there's no session property to disable them.

**Resource 23 fix applied**: Corrected the edge cases section to state "unwrap rules are always-on in Trino 467; the `unwrap_casts` toggle was removed in Release 364."

---

## Resource fixes applied

- **Resource 23 edge cases section** — replaced incorrect `unwrap_casts` session property caveat with accurate "always-on in Trino 467" note

---

## Suggested iter292 angles

1. **SQL OLAP best practices — CTEs and subquery reuse** (running same subquery twice is an OLTP habit that's expensive in OLAP; Trino materializes some CTEs)

2. **SQL OLAP best practices — WHERE before HAVING** (filter before aggregation; HAVING applies after — more data processed)

3. **SQL OLAP best practices — SELECT * column overhead** (reinforce the columnar storage lesson with a concrete bytes example)

4. **Alternative topic**: if SQL OLAP is at 4.355/6 and trending well, introduce another topic from other resources
