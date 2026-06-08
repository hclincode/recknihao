# Iter 675 — Judge Feedback

**Date**: 2026-06-08
**Phase**: extended
**Overall**: 4.50 PASS (margin +1.00 above 3.5 floor; -0.50 swing DOWN from iter674's 5.00 STRONG PASS)
**Docs-truth verification source**: trino.io/docs/467/functions/{array,aggregate}.html (WebFetched 2026-06-08)

---

## Per-question scores

### Q1 — Date-spine gap-fill (2026-01-01..today, COALESCE 0 for missing days)

**Answer**:
```sql
SELECT day, COALESCE(cnt, 0) AS signups
FROM (SELECT * FROM UNNEST(sequence(DATE '2026-01-01', CURRENT_DATE)) AS t(day)) calendar
LEFT JOIN daily_signups s ON s.day = calendar.day
ORDER BY day;
```

**Scores**: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = **5.00**

**Verdict**: Fully correct. `sequence(DATE, DATE)` 2-arg form defaults to a +1 day step per trino.io/docs/467/functions/array.html verbatim ("incrementing by 1 day if start date is less than or equal to stop date"). `UNNEST(sequence(...)) AS t(day)` date-spine + `LEFT JOIN` + `COALESCE(cnt, 0)` zero-fill is the canonical Trino 467 pattern. (Minor: `cnt` is the assumed daily_signups count column — structurally correct; only matters if the actual column is named differently.) Docs-verified.

### Q2 — Top-3 scores per user (array_sort + slice, no UNNEST)

**Answer**:
```sql
SELECT user_id,
       array_slice(array_sort(scores, (a, b) -> IF(a > b, -1, 1)), 1, 3) AS top_3_scores
FROM users
WHERE scores IS NOT NULL;
```

**Scores**: Accuracy 2 / Completeness 4 / Clarity 4 / Actionability 2 = **3.00**

**EXPLICIT VERDICT — FABRICATED FUNCTION DEFECT**: `array_slice` is **NOT a real Trino 467 function**. WebFetched trino.io/docs/467/functions/array.html on 2026-06-08 — the documented array-subsetting function is **`slice(x, start, length)`** (1-based; negative start counts from the end). `array_slice` is a Presto-legacy / Spark / other-dialect name; in Trino 467 it fails at parse time with "Function array_slice not registered". The query will NOT execute as written.

The descending-sort half is correct: `array_sort(array(T), function(T, T, int))` with the `(a,b) -> IF(a > b, -1, 1)` comparator returning -1/0/1 is the docs-correct 2-arg form (trino.io/docs/467/functions/array.html verbatim "Sorts and returns the array based on the given comparator function"). Only the wrapping slice function name is wrong.

**Correct form**:
```sql
SELECT user_id,
       slice(array_sort(scores, (a, b) -> IF(a > b, -1, 1)), 1, 3) AS top_3_scores
FROM users
WHERE scores IS NOT NULL;
```

**Root cause — LANDING-POINT-MISS**: `slice(` returns ZERO grep hits across all resources/ files (verified 2026-06-08). The responder had no canonical to anchor to and fabricated `array_slice` by family-name analogy from `array_sort`/`array_distinct`/`array_except` — exactly the failure mode the responder-findability memory note warns about. Top-N-from-pre-sorted-array is a routine SaaS pattern (leaderboards, recent-N, top scores); the responder cannot land it correctly without a canonical.

### Q3 — max_by per group (customer with largest order per product)

**Answer**:
```sql
SELECT product_id, max_by(customer_id, amount) AS customer_with_largest_order
FROM orders
GROUP BY product_id;
```

**Scores**: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = **5.00**

**Verdict**: Fully correct. WebFetched trino.io/docs/467/functions/aggregate.html — `max_by(x, y)` returns "the value of x associated with the maximum value of y" verbatim, one row per GROUP BY group. The ROW(amount, order_id) tiebreaker note (`max_by(customer_id, ROW(amount, order_id))`) is a sound deterministic-tiebreak idiom — ROW comparison is lexicographic in Trino, so ties on amount are broken by order_id. Iter638/iter656/iter658 PINs at r23:636/652 + r07:2254 anchor this landing point. Docs-verified.

### Q4 — array_except per user (categories viewed but not purchased)

**Answer**:
```sql
SELECT user_id, array_except(viewed_categories, purchased_categories) AS viewed_not_purchased
FROM users;
```

**Scores**: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = **5.00**

**Verdict**: Fully correct. WebFetched trino.io/docs/467/functions/array.html — `array_except(x, y)` "Returns an array of elements in x but not in y, without duplicates" verbatim. r07:238 §1a.3-1a.4 canonical anchors the 2-arg form. Docs-verified.

---

## Overall

**Average**: (5.00 + 3.00 + 5.00 + 5.00) / 4 = 18.00 / 4 = **4.50**

**Dim-avg cross-check**:
- Accuracy: (5+2+5+5)/4 = 4.25
- Completeness: (5+4+5+5)/4 = 4.75
- Clarity: (5+4+5+5)/4 = 4.75
- Actionability: (5+2+5+5)/4 = 4.25
- = (4.25+4.75+4.75+4.25)/4 = **4.50** — agrees.

**GOVERNING LABEL**: **PASS** (overall 4.50 >= 3.5 by margin +1.00; per-directive the overall average governs PASS/FAIL — no per-question quality-gate override).

**Flagged weak answer**: Q2 (3.00) — fabricated-function parse error on `array_slice`. The query will not run. Flagged in prose per directive; does not override the overall PASS label.

---

## Topic updates

- **Analytical query patterns on Iceberg+Trino / date-spine gap-fill** (Q1 sequence-DATE-2-arg-default-1-day + UNNEST + LEFT JOIN + COALESCE canonical durability +0.25) — HOLDS at PASSED.
- **Analytical query patterns on Iceberg+Trino / top-N-from-array (array_sort-comparator + slice)** (Q2 array_sort comparator-form CORRECT but slice landing-point MISSED → fabricated `array_slice`) — LANDING-POINT-MISS, no false claim in resources but a missing canonical. Topic remains PASSED (high prior datapoints) but this gap should be closed.
- **Analytical query patterns on Iceberg+Trino / max_by per group** (Q3 max_by + ROW-tiebreaker canonical durability +0.25) — HOLDS at PASSED.
- **Analytical query patterns on Iceberg+Trino / array set-difference (array_except)** (Q4 array_except 2-arg canonical durability +0.25) — HOLDS at PASSED.

---

## Teacher feedback — iter676 recommendation

**iter676 = FIX-A: add `slice(array, start, length)` canonical near the array_sort / top-N-from-array route**

Concrete prescription:
- **Target file**: `resources/07-...` (or wherever the §1a.3-1a.4 array HOF canonical lives — adjacent to `array_sort` + `array_distinct` + `array_except` block at ~r07:237-275).
- **Canonical to add**: `slice(array(T), start, length) -> array(T)` — "Subsets array x starting from index start (1-based; negative start counts from the end) with a length of length." Cite trino.io/docs/467/functions/array.html verbatim.
- **Worked example** (top-3-from-pre-sorted-array, the exact Q2 shape):
  ```sql
  -- top 3 descending: sort desc, then slice first 3
  SELECT user_id,
         slice(array_sort(scores, (a, b) -> IF(a > b, -1, 1)), 1, 3) AS top_3_scores
  FROM users;

  -- last 5 elements: negative start
  SELECT id, slice(events, -5, 5) AS last_5 FROM t;
  ```
- **DO-NOT-WRITE inoculation row** in the dialect-leak table: `array_slice(...)` is Presto-legacy / Spark / BigQuery — NOT Trino 467; will fail with "Function array_slice not registered". Use `slice(...)` instead.
- **Keyword anchors** (for responder findability): "take first N", "top 3 from array", "first 3 elements", "last 5 elements", "subset array", "slice array", "array_slice", "first N of sorted array", "top-N without UNNEST".
- **Cross-reference**: from the `array_sort` block + the `max_by(x, y, n)` 3-arg block (which is the GROUP-BY-aggregate alternative for top-N-per-group) — both routes converge on top-N patterns and should mention `slice()` as the per-row pre-sorted-array sibling.

**Rationale**: The Q2 failure is a clean landing-point miss, not a false claim. iter674 state.json notes (a) correctly identified `slice()` as a synthesizable-from-primitives WATCH-ITEM and held it per CLEAN-NO-OP directive. iter675's first probe into the WATCH-ITEM area landed exactly on the gap, producing a fabricated-function parse error. The gap is now confirmed real and should be closed in iter676. Cost is low (single canonical entry + worked example + DO-NOT-WRITE row); benefit is high (top-N-from-array is a routine SaaS pattern).

**Margin trajectory**: iter674 5.00 -> iter675 4.50 (-0.50). Still well above 3.5 floor by +1.00 margin. One fabricated-function defect in Q2 is the entire delta; Q1/Q3/Q4 sweep perfect 5.00. After iter676 FIX-A, expect re-probe of top-N-from-array shapes to land at 5.00.

**DO NOT**:
- Bump training/state.json (teacher already set to 675; iter676 directive scope is teacher's, not judge's).
- Touch r22 federation guardrails (consecutive non-probe streak now 31 iterations iter645-675; 4.5 threshold thin).
- Rewrite any iter534-674 locks (all HOLD — verified against trino.io/docs/467 this iteration: sequence-DATE-2-arg-default-1-day-step ✓, array_sort-2-arg-comparator-form ✓, max_by(x,y) + 3-arg variant ✓, array_except(x,y) ✓).
- Introduce `array_slice` anywhere in resources/ — it does NOT exist in Trino 467 and must be listed as DO-NOT-WRITE.
- Pre-probe other CLEAN-NO-OP WATCH-ITEMs (transform_keys/values, map_zip_with, sequence-int-step generalization, zip_with paired-array HOF) in the same iteration as the FIX-A — keep the FIX-A focused.

**Meta-note**: The CLEAN-NO-OP cadence at iter674 was correct in spirit, but iter675's first WATCH-ITEM-area probe surfaced exactly the synthesizable-from-primitives gap the teacher had held — confirming that synthesizable-WATCH-ITEMs sometimes need concrete canonicals (responder fabricates by family-name analogy when no canonical anchors the function name). FIX-A in iter676 closes this surgically without manufacturing broader churn.
