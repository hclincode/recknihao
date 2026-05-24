# Score: iter52-q2

**Topic**: Analytical query patterns on Iceberg+Trino — window functions (LAG/LEAD)
**Score**: 4.75 / 5.0

## What the answer got right
- Correct `LAG(wau, 1) OVER (ORDER BY week_start)` Trino syntax — matches official trino.io documentation (`lag(x[, offset[, default_value]])` with ORDER BY required, no frame specification).
- Complete runnable SQL with WITH CTE, `date_trunc('week', occurred_at)`, `COUNT(DISTINCT user_id)`, delta, and percent change.
- `NULLIF(LAG(...), 0)` division-by-zero protection used correctly.
- Plain-English explanation of `LAG(wau, 1) OVER (ORDER BY week_start)` broken into three parts (function, offset, OVER clause) — exactly what a beginner needs.
- First-week NULL behavior explicitly called out and framed as expected/correct.
- Self-join comparison addresses the engineer's literal question ("without joining the table to itself twice").
- Mentions `LEAD()` as the opposite (looks forward) — covers the expected bonus point.
- Goes further with `ROW_NUMBER()` and `NTILE()` as additional useful window functions (bonus over the rubric).
- Concrete example output table with realistic numbers (NULL on first row, +12.0% / −6.3% / +14.3% deltas) — makes the abstract pattern tangible.
- Production note on partition pruning with `WHERE occurred_at >= current_date - INTERVAL '13' WEEK` filter, with 10–100× speedup framing.
- Anchored to the prod stack (`iceberg.analytics.events`, Trino) throughout.

## Gaps or errors
- Minor: "single pass" framing for the window-function approach is slightly imprecise — the CTE still aggregates the events table once, then the window function runs over the small per-week result set. The user's takeaway (window functions are cheaper than a self-join) is correct, but a stricter reading of "single pass" could mislead.
- Minor: "scanning the events table twice" attributed to a self-join is approximately right but a query planner may pull both sides from one scan; the operational difference is more about query complexity/readability than physical I/O.
- Beginner-clarity nit: "window function" and "ordered window" are used in the section heading before being defined inline — the definition arrives a few paragraphs later. A one-line gloss at first mention would be ideal.

## Verdict
Strong, near-complete answer that delivers the exact LAG/CTE/NULLIF pattern with correct Trino syntax, plain-English explanation, expected-NULL callout, LEAD mention, and partition-pruning production note — comfortably above the pass threshold.
