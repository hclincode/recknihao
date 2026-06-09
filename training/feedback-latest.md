# iter801 Judge Feedback — DEFAULT NO-OP / durability-breadth sweep

**Date:** 2026-06-09
**Teacher edits this iteration:** ZERO (expected — durability-breadth sweep). Four fresh adjacent probes over well-covered fundamentals.

**Verification:** All dialect claims verified against trino.io/docs/467 (functions/array.html, functions/window.html) on 2026-06-09.

---

## Per-question scores

### Q1 — Top 3 best-selling products per category (3 rows per category by sales_count)
Answer: `ROW_NUMBER() OVER (PARTITION BY category ORDER BY sales_count DESC) AS rn` in a subquery, outer `WHERE rn <= 3`. Cites r07.

- Accuracy: 5 — VERIFIED vs window.html: row_number() returns a unique sequential number per partition starting at 1; PARTITION BY category restarts numbering per category, ORDER BY sales_count DESC ranks best-sellers first, outer WHERE rn<=3 = exact top-3-per-group. Correct.
- Completeness: 5 — subquery wrapper required (window alias not referenceable in same SELECT's WHERE) handled correctly.
- Clarity: 5 — clean partition/order/filter explanation.
- Actionability: 5 — drop-in pattern.
- **Q1 avg: 5.00 CLEAN** (standing top-N-per-group ROW_NUMBER pin held)

### Q2 — Index of 'approved' in a native string array (1-based, expect 3)
Answer: `array_position(workflow_stages, 'approved')` → 1-based index of first occurrence, 0 if not found; ARRAY['draft','review','approved','published'] → 3. Notes duplicates→first match, UNNEST WITH ORDINALITY for per-element ordinal. Cites r07 §1a.3.

- Accuracy: 5 — VERIFIED vs array.html: array_position(x, element) returns position of first occurrence (1-based) or 0 if not found; 'approved' at index 3 in the given array. Correct. WITH ORDINALITY note accurate.
- Completeness: 5 — duplicates→first-match and the per-element-ordinal alternative both covered.
- Clarity: 5 — 1-based vs 0-based ambiguity explicitly resolved (key for a non-expert).
- Actionability: 5 — exact answer + edge cases.
- **Q2 avg: 5.00 CLEAN** (standing array_position-1-based pin held)

### Q3 — Whether candidate_skills and required_skills share at least one element (true/false)
Answer: `cardinality(array_intersect(candidate_skills, required_skills)) > 0 AS has_match`; array_intersect returns deduped common elements, cardinality>0 = at least one shared. Also CASE WHEN ... THEN TRUE ELSE FALSE. Cites r07 §1a.3.

- Accuracy: 5 — VERIFIED vs array.html: array_intersect(x,y) returns the deduped intersection; cardinality(...)>0 correctly tests for at least one shared element. Correct and robust.
- Completeness: 4 — answer is correct and works. Trino 467 ALSO has the purpose-built `arrays_overlap(x, y) -> boolean` ("Tests if arrays x and y have any non-null elements in common; returns null if there are no non-null elements in common but either array contains null"). Omitting it is a MINOR completeness gap, not a defect — see verdict below.
- Clarity: 5 — cardinality>0 reasoning is arguably clearer to a non-expert than arrays_overlap's NULL semantics.
- Actionability: 5 — drop-in boolean expression.
- **Q3 avg: 4.75 CLEAN** (standing array_intersect/arrays_overlap pin held)

### Q4 — Daily consumption = current meter_value minus previous day's, ordered by date
Answer: `LAG(meter_value) OVER (ORDER BY reading_date) AS prev_day_value`; `meter_value - LAG(meter_value) OVER (ORDER BY reading_date) AS daily_consumption`; first row NULL; PARTITION BY meter_id for multiple meters. Cites r07 Pattern B.

- Accuracy: 5 — VERIFIED vs window.html: lag(x[, offset[, default]]) with default offset 1 returns the prior row's value, NULL on the first row of the partition with no default; meter_value - LAG(...) = consecutive delta. PARTITION BY meter_id correctly isolates each series. Correct.
- Completeness: 5 — first-row-NULL behavior and multi-meter partitioning both addressed.
- Clarity: 5 — clear step from prev-value to delta.
- Actionability: 5 — drop-in.
- **Q4 avg: 5.00 CLEAN** (bulletproofed LAG-consecutive-delta pin held)

---

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|-----|------|------|-----|-----|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | 5 | 4 | 5 | 5 | 4.75 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall avg: 4.94 — PASS** (threshold 3.5; no single-Q veto, and none would apply anyway).

---

## Teacher feedback

**(a) Q3 arrays_overlap verdict — FINE AS-IS (optional one-line completeness note, NOT a defect).**
The responder's `cardinality(array_intersect(a,b)) > 0` is fully correct, docs-verified, and returns a clean boolean. Trino 467's purpose-built `arrays_overlap(x,y) -> boolean` is the more direct single-function answer, BUT it carries a NULL-handling subtlety (returns NULL — not false — when there are no non-null elements in common and either array contains null). The responder's form avoids that subtlety and is arguably clearer to a non-expert. Treat arrays_overlap as an optional alternative the teacher MAY surface in r07 §1a.3 as a one-liner ("more direct: `arrays_overlap(a,b)`, but note its NULL-when-either-contains-null behavior") — do NOT churn the verified array_intersect card to make it the primary. No score penalty beyond the single Comp=4 on Q3.

**(b) iter802 designation — DEFAULT NO-OP / durability-breadth.**
No open defect, no findability miss, all four standing pins held clean (top-N-per-group-ROW_NUMBER, array_position-1-based, array_intersect/arrays_overlap, LAG-consecutive-delta). No FIX-A warranted.

Suggested fresh adjacent probes for iter802 (probe-only; do not edit resources): arrays_overlap as the LEAD form of a "do these sets intersect" question (bank a datapoint on the direct function), array_distinct/array_sort, NTILE for quartile bucketing, FIRST_VALUE/LAST_VALUE with explicit frame, sequence()/UNNEST for gap-filling dates.

**PRESERVE** (verified clean, churn risk): r07 ROW_NUMBER top-N-per-group, r07 §1a.3 array_position / array_intersect, r07 Pattern B LAG cards.
