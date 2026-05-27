# Iter26 Q3 Score

**Question**: Billing team wants a monthly MRR report showing revenue per plan type and month-over-month change per plan. How do you write this in Trino?
**Topic**: Common analytical query patterns
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 5 |
| Practical applicability | 4.75 |
| Completeness | 5 |
| **Average** | **4.875** |

**Feedback**: Outstanding beginner clarity — shows intermediate result tables at each CTE step, defines CTEs and window functions inline with plain-English descriptions before any SQL appears. Two-CTE structure (monthly aggregation → LAG for prior period) is exactly the right pattern. `date_trunc('month', changed_at)` correct Trino syntax. `LAG(total_mrr_cents) OVER (PARTITION BY plan_type ORDER BY month)` correct idiom. Division-by-zero guard with CASE WHEN for first-month NULL is correct and important. Pre-aggregated rollup table recommendation for dashboard performance is actionable. Pitfalls section (change_type filter, money in cents, NULL first-month, churn hidden in free plan) is the most comprehensive in the iteration. Variations (YoY, geography, cumulative ARR) directly actionable. Minor: HTML entities in code blocks throughout; billing table schema (`subscription_changes` with `to_plan`, `new_mrr_cents`) and dbt reference are not in resources — assumed/hallucinated but plausible and internally consistent.
