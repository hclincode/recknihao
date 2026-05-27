# Iter 14 Q3 — ClickHouse at 5M rows: is operational complexity worth it?

## Question summary
A SaaS engineer with 3–8 second Postgres analytics queries asks whether adding ClickHouse is worth the operational complexity when a friend claimed it would run the same queries in 50ms. At 5 million rows, is migration justified?

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All specific claims verified against the resource and external benchmarks. The four Postgres tuning steps (read replica, EXPLAIN ANALYZE, materialized views, date partitioning) are correct and match `resources/06-when-to-add-olap.md` precisely. The two-of-four threshold rule (>50M rows, >2s after tuning, >3 ad-hoc users, >1 source) matches the resource table exactly. The friend's 50ms ClickHouse claim is implausible at 5M rows for simple queries but plausible for complex OLAP aggregations — the answer sidesteps rather than corrects this, which is acceptable. The critical prod_info.md grounding is correct: the on-prem stack already has Trino+Iceberg, making ClickHouse redundant. No factual errors. |
| Beginner clarity | 4 | The threshold table is concrete and scannable — strong structure for a beginner. The "probably not worth it yet" framing directly answers the question without requiring prior knowledge. However, "read replica," "EXPLAIN ANALYZE," "materialized views," and "date partitioning" are all used without inline plain-English glosses. The resource has a Key Terms table with these definitions but the responder did not surface them inline. A beginner following the tuning checklist would need to look up each term independently. Also missing: why ClickHouse (and Trino+Iceberg) are faster — explaining "columnar storage reads only the columns a query touches instead of whole rows" would have grounded the performance claim for a beginner. |
| Practical applicability | 4 | The engineer gets a direct verdict (no, not yet), a four-step Postgres tuning ladder, and a concrete threshold table to revisit later. The prod-stack grounding (use Trino+Iceberg if you do move, not ClickHouse) is highly actionable given that the stack is already in place. Deductions: (1) none of the four tuning steps explain HOW to implement them — "EXPLAIN ANALYZE to find missing indexes" leaves the engineer without a next action if they've never run EXPLAIN ANALYZE; (2) no guidance on how to measure current query latency to know whether you've hit the 2s threshold (pg_stat_statements for capturing slow queries is in the resource but not surfaced); (3) "when at least 2 of these are true" is correctly stated but the engineer's own situation (5M rows = below 50M threshold) should be called out explicitly as "you haven't hit threshold 1 yet." |
| Completeness | 4 | Answers the core question and addresses the 5M rows context well. The ClickHouse-redundancy angle is the right prod_info.md-grounding move. Gaps: (1) the "cost of moving too early" section from the resource ("two systems to operate, two schemas to keep in sync, two query languages, double on-call surface") was not surfaced — this is the exact argument the engineer needs to make to stakeholders when pushing back on the friend's ClickHouse suggestion; (2) the 50ms claim is accepted without explaining that columnar storage (which Trino+Iceberg also provides via Parquet) is why OLAP systems are faster — this explanation would have made the ClickHouse-is-redundant point land harder; (3) no explicit statement that at 5M rows the engineer has not triggered even threshold 1 (>50M rows), which would have made the answer more definitive. |
| **Average** | **4.25** | |

## Topic updated

**Topic**: When to add an OLAP layer vs staying on the transactional DB
- Prior avg: 4.375 (2 questions: Iter 2 Q5 = 4.0, Iter 5 Q1 = 4.75)
- New score: 4.25
- New running avg: (4.0 + 4.75 + 4.25) / 3 = **4.333**
- Status: PASSED (avg 4.333 >= 3.5 threshold, 3 questions from distinct angles)

## Key finding

The answer correctly executes the most important move for this question: re-anchor to the production environment. The engineer asked about ClickHouse vs Postgres; the answer correctly identifies that the on-prem stack already has Trino+Iceberg, so ClickHouse would be a third system layered on top of an existing OLAP solution. That grounding deserves full marks on technical accuracy. The threshold table from the resource is applied directly to the engineer's situation (5M rows < 50M threshold), giving a concrete verdict.

The persistent beginner-clarity gap is terminology used without inline glosses. This is the same issue flagged in the Iter 5 Q1 score note for this same topic — "tuning terms used without inline one-line glosses." The resource's Key Terms section has these definitions but the responder does not surface them inline. This is a resource instruction problem, not a missing resource.

The completeness gap is the "cost of moving too early" framing. The question explicitly uses the phrase "slow but not broken" — the engineer is already framing the trade-off themselves and inviting the responder to quantify the cost of acting on the friend's advice. The resource has an entire subsection ("The #1 mistake: adding OLAP too early") with a concrete example of a team with 8M rows who spent six months running two systems. That subsection is a direct answer to this question's framing and was not surfaced.

## Resource gap

No new resource gaps. The existing `resources/06-when-to-add-olap.md` covers all the content needed for a complete answer. The gaps are in retrieval and surfacing:

1. The Key Terms glossary at the bottom of the resource is not being reproduced inline for beginner-facing terms (read replica, EXPLAIN ANALYZE, materialized view). Consider adding a "Quick glossary — read this first" callout box at the top of the Postgres tuning checklist section.

2. The "cost of moving too early" subsection and the concrete 8M-row team example are not being surfaced when the engineer's question framing calls for exactly that content. Consider adding a "Before you move — quantify the cost" callout immediately after the threshold table, referencing the cost items by name so the responder surfaces them when answering "is it worth it?" questions.
