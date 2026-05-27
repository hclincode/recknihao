# Iter24 Q3 Score

**Question**: Find first action after onboarding funnel drop-off for each user in Trino (dropped off at profile complete, never paid).
**Topic**: Common analytical query patterns
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 5 |
| **Average** | **4.81** |

**Feedback**: Excellent approach. EXCEPT-based anti-join for drop-off cohort identification is the correct and clean idiom. ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY event_time ASC) is the correct Trino window function for "first event per user." Three useful variations included: (1) users who never returned (LEFT JOIN + COALESCE), (2) time-to-next-action (date_diff), (3) eventual conversion rate (UNION ALL pattern). event_date partition filter correctly included for performance. PERCENTILE_CONT WITHIN GROUP syntax is valid Trino SQL. Minor issues: (1) CALL iceberg.system.rewrite_data_files() mentioned in the debugging section without an explicit "Spark SQL only" label inline (says "see iceberg-maintenance resource" which defers the label); (2) HTML entity encoding (`&gt;`) in code blocks; (3) the percentage calculation `SUM(COUNT(DISTINCT user_id)) OVER ()` is a nested window aggregate that may require checking in Trino 467 — simpler to compute total separately in a CTE.
