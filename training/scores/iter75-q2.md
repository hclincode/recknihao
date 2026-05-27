# Iter 75 Q2 — Judge Score

**Topic**: Common analytical query patterns
**Score date**: 2026-05-25

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4.5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.875** |

## Points covered
1. **Naive COUNT-per-event wrong** — Covered (first paragraph): "counting each event type separately and dividing is wrong. A funnel requires that the same user completed both step N and step N+1, in time order." Reinforced in the "Common mistakes" table.
2. **CTE-based pattern with ordered JOINs** — Covered fully. step1 builds base; step2..step5 each JOIN back to the events table filtered by the prior step's users.
3. **`occurred_at > previous_step_time` constraint** — Covered (in every step CTE) and explained in "What each part does": "a user who purchased before completing onboarding (an edge case) doesn't count as an onboarding → purchase conversion."
4. **`COUNT(DISTINCT user_id)` not `COUNT(*)`** — Covered. Explained at the top ("a user visiting the landing page 5 times should count once"), used in the counts CTE, and reinforced in the mistakes table.
5. **LEFT JOIN semantics in counts CTE** — Covered. counts CTE uses LEFT JOIN from step1 to step2..step5. Explained: "users who dropped off at any point contribute a NULL to the later steps. COUNT(DISTINCT user_id) over LEFT JOIN results correctly counts only users who made it to each step."
6. **`NULLIF(denominator, 0)`** — Covered. Used in all four ratio expressions; explained as preventing division-by-zero.
7. **Complete working SQL** — Covered. Full 5-step funnel matching the engineer's exact step names (landing_page_visit, account_created, email_verified, onboarding_completed, first_purchase) with tenant_id filter, ready to copy/run.

## Issues found
- Minor: `MIN(occurred_at)` is captured in each step CTE but only the chained step's `step_time` is used downstream; step1 uses MIN for first-visit semantics, which is correct. No functional issue.
- Minor: The counts CTE produces a single row, so wrapping `COUNT(DISTINCT)` aggregations works because the LEFT JOINs may produce duplicate (s1.user_id, sN.user_id) pairs only if a user appears multiple times in step CTEs — but each step CTE GROUPs BY user_id, so each user appears once per step CTE. DISTINCT is defensive but correct. Not an issue.
- Minor clarity: A complete beginner may not instantly grasp why we re-JOIN all steps back in the counts CTE rather than just `SELECT COUNT(*) FROM stepN`. The answer does explain this, but the rationale ("we need all counts in one row so the UNION ALL can reference n1..n5") could be more explicit. This is the only thing keeping beginner clarity from a 5.
- The performance section mentions "partitioned by `tenant_id` (the recommended pattern)" — fine and matches the prod stack's multi-tenant pattern.

## Accuracy verification
Verified via WebSearch against trino.io official documentation:
- **NULLIF**: Confirmed as a standard Trino conditional expression valid in Trino 467. `NULLIF(n1, 0)` returning NULL when n1 = 0 is correct behavior; dividing by NULL yields NULL, avoiding the "Division by zero" error.
- **CTEs / WITH clauses**: Confirmed Trino supports chained CTEs; each CTE can reference prior CTEs. The pattern used is standard.
- **`MIN(occurred_at)` with GROUP BY in CTEs**: Standard aggregate behavior; verified.
- **`COUNT(DISTINCT user_id)` over LEFT JOIN**: Confirmed Trino's COUNT ignores NULLs (per aggregate functions docs), so users who didn't reach step N contribute NULL to sN.user_id and are correctly excluded from `COUNT(DISTINCT sN.user_id)`. The LEFT JOIN semantics are correctly leveraged.
- **`CURRENT_DATE - INTERVAL '30' DAY`**: Confirmed valid Trino datetime syntax.
- **`ROUND(100.0 * n2 / NULLIF(n1,0), 1)`**: ROUND with two numeric args (value, decimals) is standard Trino math function syntax — verified.
- All identifiers (`iceberg.analytics.events`, three-part naming) are consistent with the prod Iceberg connector setup described in prod_info.md.

## Resource fix needed?
No. The answer is high-quality, complete, accurate, and copy-pasteable. The CTE+ordered-JOIN funnel pattern matches the canonical Trino approach. No teacher action needed for this topic.

## Updated topic average
Prior: 4.602 across 8 questions
New: (4.602 × 8 + 4.875) / 9 = **4.633** across 9 questions
Status: **PASSED**
