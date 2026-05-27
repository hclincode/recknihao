# Iter 4 Q4 — Cohort retention query

## Scores
- Technical accuracy: 5
- Beginner clarity: 4
- Practical applicability: 5
- Completeness: 4
- Average: 4.50

## Topic updated
- Topic name: "Common analytical query patterns: aggregations, funnels, cohort, time-series"
- Prior questions: 0 → 1
- New avg: 4.50

(Note: this topic was previously listed as separate from "Analytical query patterns on Iceberg+Trino" — this question maps most naturally to the generic-patterns topic since it foregrounds standard SQL and the cohort matrix output, not stack-specific tuning.)

## Key finding
Strong answer that does the most important pedagogical move first: shows the **output shape** (cohort × week-offset matrix) before any SQL, so the engineer knows what they're aiming for. The 3-CTE walk (cohorts → activity → pivot) follows `07-analytical-query-patterns.md` exactly, with the correct idiom (`date_trunc('week', MIN(event_time))` for cohort assignment, `date_diff('week', cohort_week, event_time)` for offset, `COUNT(DISTINCT user_id)` per cell). Calling out `approx_distinct()` with the ~2% error / 100x memory framing is the right level of nuance for an "investor dashboard" use case where exact counts don't matter. The Iceberg partition-pruning callout grounds the answer in the prod stack rather than leaving it as a generic SQL exercise.

## Resource gap for next iteration
Two small gaps worth closing on a future pass, both clarity-related:
1. **CASE WHEN pivot is the standard idiom for `week_N` columns** but the resource shows the long-form `(cohort_week, week_offset)` row-per-cell shape, not the wide pivot the answer described. Investors will want the wide format. Add a wide-pivot variant (or note that BI tools like Superset/Metabase pivot client-side) to `07-analytical-query-patterns.md` section 3.
2. **Cohort-size denominator is implicit.** The retention *percentage* (week_N / week_0) is what investors actually read, but neither the resource nor the answer shows the division explicitly. A 2-line addition — `active_users * 100.0 / FIRST_VALUE(active_users) OVER (PARTITION BY cohort_week ORDER BY week_offset)` — would close the loop from "raw counts" to "retention %."

Neither gap is severe enough to fail the answer; both would push the next cohort question to 4.75–5.0.
