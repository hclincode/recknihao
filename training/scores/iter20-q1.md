# Iter20 Q1 Score

**Question**: Period-over-period WAU comparison — how to write a query that returns both current and prior period so PM can show "up 12% from last week"
**Topic**: Common analytical query patterns
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4.5 |
| Practical applicability | 5 |
| Completeness | 4.5 |
| **Average** | **4.75** |

**Feedback**: Excellent coverage. CTE+LEFT JOIN pattern is correct and well-explained. date_trunc, INTERVAL, and all Trino 467 syntax are accurate. Division-by-zero guard included. UNION ALL for trend charts and LAG() advanced alternative both covered. Timezone and late-arriving event gotchas are practical. Docks slightly on clarity/completeness — answer is thorough to the point of being dense for a true beginner, and the multi-metric dashboard query section adds length without proportional benefit.
