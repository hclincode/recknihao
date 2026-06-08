# iter746 Judge Feedback — durability-breadth (rolling-avg / array-intersect / pivot / map-merge)

**Verification basis**: all 4 claims checked against trino.io/docs/467 (functions/window.html, array.html, aggregate.html, map.html) via WebSearch 2026-06-09. resources/ NOT treated as ground truth.

## Docs verification summary (highest-risk first)

- **map_concat duplicate-key winner** (Q4, FLAGGED HIGHEST RISK): CONFIRMED — Trino docs verbatim "If a key is found in multiple given maps, that key's value in the resulting map comes from the last one of those maps." Responder's claim "rightmost/last map wins → put overrides last" is EXACTLY CORRECT. Worked example `{'theme':'light','timeout':'30'} + {'theme':'dark'} -> {'theme':'dark','timeout':'30'}` is correct. `MAP()` empty-map constructor for the COALESCE null-safe variant is valid Trino 467 syntax.
- **array set-op signatures** (Q2, FLAGGED HIGH RISK): CONFIRMED — `array_intersect(x,y)` = elements in intersection without duplicates; `array_union(x,y)` = union without duplicates; `array_except(x,y)` = elements in x but not y, without duplicates. All three docs-verbatim. Responder's dedup characterization is correct on all three.
- **Window moving-frame** (Q1): CONFIRMED — `AVG(x) OVER (ORDER BY d ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)` = 7-row sliding window (current + 6 preceding), NOT a running total. Pre-aggregating to one row per day in the CTE before applying the frame is the correct idiom (frame counts ROWS, so one-row-per-day is required for "7 days"). Responder surfaced both points explicitly.
- **Aggregate FILTER clause** (Q3): CONFIRMED — `SUM(x) FILTER (WHERE cond)` is valid Trino 467 syntax, supported for all aggregate functions; docs-verbatim form is `aggregate_function(col) FILTER (WHERE condition)`. SUM(CASE WHEN ... THEN ... END) pivot is also correct.

## Per-question scores

### Q1 — 7-day rolling/moving average
- Accuracy: 5 — correct window frame, correct ROWS BETWEEN 6 PRECEDING AND CURRENT ROW = 7 rows.
- Completeness: 5 — pre-aggregate-to-one-row-per-day caveat included (the exact trap the run-prompt flagged); SUM-for-revenue variant offered.
- Clarity: 5 — "this day + 6 back = 7 rows" plainly explained for a non-OLAP engineer.
- Actionability: 5 — drop-in CTE, ORDER BY present, ready to run.
- **Q1 avg = 5.00**

### Q2 — common elements between two arrays
- Accuracy: 5 — array_intersect docs-verbatim, dedup behavior correct.
- Completeness: 5 — bonus array_union / array_except correctly characterized (union all-deduped, except a-not-b), covering the adjacent set-ops the engineer will reach for next.
- Clarity: 5 — "elements in both, deduped" is exact and jargon-free.
- Actionability: 5 — single-line drop-in against a realistic user_plans table.
- **Q2 avg = 5.00**

### Q3 — pivot rows into columns
- Accuracy: 5 — SUM(CASE WHEN...) pivot correct; FILTER (WHERE...) equivalent is valid Trino 467.
- Completeness: 4.5 — explained CASE-returns-NULL/SUM-ignores-NULL mechanic and offered the cleaner FILTER form. Minor ding: used `ELSE 0` in the CASE form, which yields 0 (not NULL) for a customer missing a metric; the run-prompt flagged this implication. The responder explained the SUM-ignores-NULL mechanic generally but did not explicitly contrast ELSE 0 (missing-metric shows 0) vs omit-ELSE (missing-metric shows NULL). Both are defensible outputs; the gap is only that the implication wasn't surfaced for the reader to choose.
- Clarity: 5 — "each CASE branch = one column" is the right mental model for a beginner.
- Actionability: 4.5 — fully runnable; reader may not realize the 0-vs-NULL choice matters for sparse data without the explicit note.
- **Q3 avg = 4.75**

### Q4 — merge two MAP columns, overrides win
- Accuracy: 5 — map_concat rightmost-wins CONFIRMED docs-verbatim; this was the iteration's highest-risk claim and it is exactly right.
- Completeness: 5 — keys-only-in-one carry-through noted; null-safe COALESCE + MAP() variant included.
- Clarity: 5 — worked example shows override winning on `theme` while `timeout` carries through; unambiguous.
- Actionability: 5 — "put overrides last" is the precise, correct instruction; drop-in.
- **Q4 avg = 5.00**

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | 5 | 4.5 | 5 | 4.5 | 4.75 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall avg = 4.9375 → PASS** (threshold 3.5; clear, no single-Q veto applies and none needed).

## iter747 designation

**DEFAULT NO-OP / durability-breadth integrity sweep.** No new defect, no gap. The two highest-risk dialect claims this iteration (map_concat rightmost-wins, array set-op dedup signatures) are docs-confirmed correct — strong durability signal on the map/array set-op surface.

OPTIONAL low-priority teacher note (NOT blocking, Q3 only): at the pivot resource, add one line making the `ELSE 0` vs omit-ELSE (→ NULL via SUM-ignores-NULL) implication explicit for sparse/missing-metric customers, so the reader can choose intended output. Pure additive co-location; do NOT reconcile or rewrite the working CASE/FILTER canonical (perfect-score-adjacent iteration, iter693 churn-risk). Q1/Q2/Q4 are perfect — do NOT touch those resources.
