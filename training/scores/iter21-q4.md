# Iter21 Q4 Score

**Question**: PM wants cohort retention curve: of users who signed up in March, how many were still active 1, 2, 4 weeks later? How to write this in Trino with events and users tables.
**Topic**: Common analytical query patterns
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 4.75 |
| **Average** | **4.94** |

**Feedback**: Excellent. Two-CTE approach (cohorts + activity) is correct and clearly explained. date_trunc and date_diff Trino functions used correctly. CASE WHEN pivot logic is accurate. COUNT(DISTINCT) vs approx_distinct guidance is practical and correctly bounded (>10M use approx). "What you're building" mental model before the SQL is ideal beginner framing. Adaptation notes (event_type filter, timestamp vs date column) are practical. Long and wide format options for BI tools are thoughtful. Minor dock on completeness — answer is comprehensive but the "Optional: Long format output" section is a bit verbose for a beginner who just needs to see the retention curve.
