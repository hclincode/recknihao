# Iter 5 Q4 — approx_distinct() accuracy for customer-facing dashboards

## Scores
- Technical accuracy: 4
- Beginner clarity: 4
- Practical applicability: 3
- Completeness: 2
- Average: 3.25

## Topic updated
- Topic name: "Common analytical query patterns: aggregations, funnels, cohort, time-series"
- Prior: avg 4.50, 1 question → now 2 questions
- New running avg: (4.50 + 3.25) / 2 = 3.875

## Key finding
The responder correctly stated the ~2% HyperLogLog figure and appropriately admitted the resources don't cover error confidence intervals or size-dependent behavior — an honest refusal to hallucinate. However, the core question ("is there a threshold below which COUNT(DISTINCT) is better?") went unanswered, leaving the engineer without a decision rule. The "run a validation test" suggestion is directionally right but too vague to be immediately actionable.

## Resource gap
CRITICAL: Add a "approx_distinct vs COUNT(DISTINCT) — when to use each" subsection to resources/07-analytical-query-patterns.md covering:
1. HyperLogLog 2% is a standard deviation (σ), not a maximum — actual max error in practice is ~6-7σ on rare hash collisions, but for typical SaaS cohort sizes (1K–10M users) the real-world error is well within 2%.
2. Decision rule: use COUNT(DISTINCT) when (a) cohort size < 1M users (fast enough, no memory pressure), (b) numbers are customer-facing and must match the app exactly, or (c) you're computing revenue or billing metrics. Use approx_distinct when (a) cohort size > 10M users and query is timing out, or (b) numbers are internal/operational dashboards where ~2% error is acceptable.
3. The validation recipe: run both on a sample partition, compute (approx - exact) / exact × 100 for your actual data shape.
