# Score: Iteration 15, Question 1

**Date**: 2026-05-24
**Phase**: Final
**Question**: Why does a GROUP BY / COUNT query slow down so much worse than a point-lookup as rows grow? (10M rows, 45s vs 2s, Postgres)
**Rubric topics covered**: OLAP vs OLTP; When to add an OLAP layer vs staying on the transactional DB

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | All core mechanics correct and verified: B-tree logarithmic depth growth (web-confirmed depth 4–5 for millions of rows), row-oriented penalty (Postgres must read every column to retrieve any column — web-confirmed), OLAP columnar layout explanation accurate, "60–90% I/O reduction" directionally correct. "10x data → 10x scan cost" is a useful simplification (real degradation can be worse than linear when aggregation state grows). Minor: answer opens with "prod_info.md does not have the production stack filled in" — but prod_info.md IS fully populated with an on-prem Trino+Iceberg+MinIO+k8s stack. This is a fact-gathering error that does not affect the technical claims themselves but does affect what follows. |
| Beginner clarity | 5.0 | Exemplary zero-assumed-knowledge framing throughout. Opens with a plain-English summary before any SQL. Numbered list of steps Postgres must execute for an aggregate query. Physical "row by row" vs "column by column" layout metaphor is concrete. B-tree explained briefly inline. Index-doesn't-solve-aggregation section addresses the most common misconception. No unexplained jargon. This is the best beginner-clarity execution seen across all 15 iterations for this topic. |
| Practical applicability | 3.5 | Read replica and materialized view recommendations are correct and actionable. However, the third option ("Dedicated OLAP system") recommends ClickHouse, BigQuery, and Snowflake — all of which are either incompatible with the on-prem production constraint (BigQuery, Snowflake are public-cloud-only; ClickHouse would be a redundant third system) or require ignoring the fact that Trino+Iceberg is already running on-prem. The answer treats prod_info.md as unfilled when it is filled. The correct recommendation is "start using the Trino+Iceberg lakehouse you already have" — exactly what `resources/06-when-to-add-olap.md` opens with. An engineer reading this answer will not know the correct next step. This is the same re-anchoring failure flagged in Iter 2 Q5, praised when fixed in Iter 4 Q3 and Iter 5 Q1. |
| Completeness | 4.5 | Core question (why aggregation scales worse than point-lookup) fully and thoroughly answered across four separate mechanisms: I/O volume, row-oriented read penalty, aggregation state, resource contention. Index-not-the-solution section is a strong bonus. "What to do" section covers all three tiers. One point docked: (1) wrong tool names in the OLAP tier — should name Trino+Iceberg (the stack already deployed) not cloud products; (2) "cost of moving too early" content from `06-when-to-add-olap.md` not surfaced. |
| **Average** | **4.375** | Above 3.5 pass threshold. |

---

## What the answer got right

1. B-tree logarithmic growth — "maybe one extra level" between 1M and 10M rows — technically correct and verified against PostgreSQL documentation.
2. Row-oriented penalty — the mechanism (must read every column's bytes to access any column) is accurate and clearly explained.
3. Four-step aggregate query cost breakdown (scan every row, read entire row, aggregate in memory, compete for I/O) — well-structured and pedagogically effective.
4. Why indexes don't fully solve it — directly addresses the most common misconception a Postgres developer will have.
5. The OLTP/OLAP structural mismatch framing is exactly what resources/01-olap-vs-oltp.md teaches, accurately reproduced.
6. Read replica and materialized view recommendations are correctly scoped as intermediate steps.

---

## What the answer missed or got wrong

1. **prod_info.md read failure (moderate).** The answer states "prod_info.md does not have the production stack filled in." prod_info.md IS fully populated. This causes the answer to recommend BigQuery, Snowflake, and ClickHouse when the correct recommendation is "use the Trino+Iceberg+MinIO lakehouse you already have." This is the most consequential error — an engineer following the answer would consider buying a new cloud product instead of using the stack already running in their k8s cluster.

2. **"Cost of moving too early" missing.** `resources/06-when-to-add-olap.md` includes an explicit "The #1 mistake: adding OLAP too early" section with a concrete team example. This content was not surfaced. At 10M rows — below the 50M threshold — the tuning checklist is the correct first recommendation, not "consider ClickHouse."

3. **Linear degradation claim slightly overstated.** "10x the data — 10x the scan cost" is a useful approximation but aggregation workloads can degrade super-linearly (aggregation hash tables grow, memory spills to disk, CPU serializes on lock contention). The answer does not need to go deep here, but the strict linear framing could mislead.

---

## Resource gap recommendations

### resources/06-when-to-add-olap.md

No new gaps. The resource already has the correct content (on-prem note at the top, threshold table, the "adding OLAP too early" section). The responder failed to read prod_info.md correctly, not because the resource is missing content.

### resources/01-olap-vs-oltp.md

No new gaps. The resource already has "Why read replicas help but don't fully solve it" and the structural-mismatch framing. The responder reproduced the core content correctly.

### Structural observation

The prod_info.md read failure is a responder behavior issue, not a resource content issue. The resources correctly note the production stack. The responder's opening disclaimer ("prod_info.md not filled in") is factually wrong and leads to wrong tool recommendations. This may indicate the responder is using a cached or stale read of prod_info.md, or is not reading it at the start of each question. This is a behavioral failure in the weak-ai-responder that cannot be fixed by editing resources — it must be addressed in the responder's prompting or initialization.

---

## Topic score updates

**OLAP vs OLTP — difference and why it matters for SaaS**
- Prior: avg 4.625 across 2 questions
- This answer: 4.375 (3rd angle — "why aggregation hurts worse" framing)
- New running avg: (5.0 + 4.25 + 4.375) / 3 = **4.542** across 3 questions
- Status: PASSED (unchanged)

**When to add an OLAP layer vs staying on the transactional DB**
- Prior: avg 4.333 across 3 questions
- This answer: 4.375 (4th angle — practical advice from the structural-mismatch explanation)
- New running avg: (4.0 + 4.75 + 4.25 + 4.375) / 4 = **4.344** across 4 questions
- Status: PASSED (unchanged)
