# Score: Iteration 16, Question 2

**Date**: 2026-05-24
**Phase**: Final
**Question**: I keep seeing options like day(), month(), bucket(), and truncate() mentioned when setting up analytics tables. What do these transforms do differently from each other? And for our tenant ID column — should we partition by tenant ID directly, or use one of these other options?
**Rubric topics covered**: Iceberg partition design for SaaS; Multi-tenant analytics

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.75 | day(), month(), bucket(), truncate() all correctly explained. Partition cardinality math (80 tenants × 365 days = 29,200/year) is correct and a useful concrete check. Day-first ordering recommendation (day + tenant_id, not tenant_id + day) is correct and matches resources. "Hidden partitioning" concept correctly explained — write WHERE occurred_at >= ..., not WHERE event_day = .... Minor: says "partition spec at table creation is permanent" — while partition evolution exists in Iceberg, the clarification "(well, you can evolve it, but that's expensive)" is present; acceptable. |
| Beginner clarity | 4.75 | Excellent structure: each transform gets its own "Use when" and "Trade-off" paragraph. The hidden partitioning section is concrete — the "don't write WHERE event_day = ..." anti-pattern is exactly what engineers need to see. Referenced production stack thresholds (80 tenants from prod_info.md) grounds the recommendation. |
| Practical applicability | 4.75 | Correctly uses production stack data (80 tenants, Iceberg 1.5.2, Spark, Trino 467, MinIO). Gives a specific actionable recommendation: partition by (day(occurred_at), tenant_id). |
| Completeness | 4.75 | Covers all four transforms, explains the 80-tenant reasoning, gives partition order rationale, explains hidden partitioning. Minor gap: doesn't mention partition evolution (if they want to change it later — covered by Q1 though). |
| **Average** | **4.75** | Strongest Iceberg partition design answer of any iteration. |

---

## What the answer got right

1. All four transforms (day, month, bucket, truncate) correctly explained with concrete use cases.
2. Specific recommendation for 80 tenants: (day(occurred_at), tenant_id) — correct.
3. Partition cardinality check (29,200/year) is the right kind of mental math to include.
4. Day-first ordering rationale (mix of cross-tenant and per-tenant queries) — correct.
5. Hidden partitioning example with explicit anti-pattern (don't write WHERE event_day = ...) — excellent.
6. Production stack correctly referenced (80 tenants from prod_info.md, Trino 467, Iceberg 1.5.2).

## What the answer missed

1. **bucket() pruning nuance.** Answer says "Trino still has to open all 64 buckets to find which one contains Acme." This is not quite right — Iceberg knows which bucket a given hash maps to, so it CAN prune to the single correct bucket for an exact tenant_id equality filter. The limitation of bucket() is partition skew (different tenants map to the same bucket) and complexity, not inability to prune. Minor accuracy issue.

---

## Topic score updates

**Iceberg partition design for SaaS**
- Prior after Q1 this iter: avg 4.333 across 3 questions
- This answer: 4.75 (4th angle — partition transforms and tenant_id strategy)
- New running avg: (13.00 + 4.75) / 4 = **4.438** across 4 questions
- Status: PASSED (significantly improved from original 4.125)

**Multi-tenant analytics**
- Prior: avg 3.912 across 12 questions
- This answer touches multi-tenant partitioning: 4.75
- New running avg: (prior_sum + 4.75) / 13 = approximately **3.969** across 13 questions
- Status: PASSED (improved)
