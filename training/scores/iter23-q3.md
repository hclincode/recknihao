# Iter23 Q3 Score

**Question**: Write funnel analysis SQL in Trino for 5-step funnel: sign up → complete profile → first payment → create project → invite team member. Show conversion rates at each step.
**Topic**: Common analytical query patterns
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 4.75 |
| Completeness | 5 |
| **Average** | **4.94** |

**Feedback**: Correct CTE/JOIN funnel approach for 5-step funnel. Conversion rate calculation at each step is accurate. Step-over-step vs total conversion distinction is clear. MATCH_RECOGNIZE mentioned as alternative for performance-critical or complex funnels. Minor: the answer briefly suggests `CALL iceberg.system.rewrite_data_files()` as a performance tip without labeling it Spark-only — a reader optimizing their funnel query could mistakenly attempt this in Trino.
