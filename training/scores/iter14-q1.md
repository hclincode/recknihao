# Iter 14 Q1 — Fact table vs dimension table: events vs users (beginner angle)

## Question summary
A SaaS engineer with Postgres experience asked whether a "fact table" is just the biggest table or something specific, using their events table and users table as concrete examples. They want to understand the terminology and which is which.

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All claims are correct: fact table = append-only rows of things that happened; dimension table = slowly-changing entity lookup; events = fact, users = dimension; denormalization via copying plan_type/country into the fact at ingest time; Parquet dictionary encoding making repeated low-cardinality values cheap — verified against official Parquet docs and the resource. No factual errors. |
| Beginner clarity | 5 | Opens with the direct correction ("not about size — it's about role"). Uses the engineer's own table names throughout. Explains every concept in plain English before naming it. "Append-only, grows endlessly" vs "small, changes slowly" is a clean contrast requiring zero prior OLAP knowledge. The dictionary-encoding explanation for why duplication cost is minimal is accurate and accessible. |
| Practical applicability | 5 | Immediately answers the concrete question (events = fact, users = dimension). The "copy plan_type, country from users into events at ingest time" instruction is directly actionable. The "avoid expensive JOINs during queries" rationale explains the why. Engineer knows the next concrete step. |
| Completeness | 4 | Fully answers the question asked and includes the denormalization angle — which is the critical "so what?" follow-through. One point docked: grain (what one row of the fact table represents) is not named or explained, and the answer does not ground the example in the production stack (Trino + Iceberg + MinIO + Spark), which the resource does explicitly. Neither omission materially damages a beginner's understanding of this specific question, but both would help depth. |
| **Average** | **4.75** | |

## Topic updated

**Topic**: Lakehouse schema design: fact tables, dimension tables, denormalization
- Prior avg: 4.50 (2 questions: Iter 3 Q1 = 4.25, Iter 6 Q4 = 4.75)
- New score: 4.75
- New running avg: (4.25 + 4.75 + 4.75) / 3 = **4.583** across 3 questions
- Status: PASSED (avg 4.583 >= 3.5 threshold, 3 questions asked from distinct angles)

## Key finding
The answer is well-calibrated for a beginner asking a foundational question. It correctly distinguishes fact vs dimension by role (not size), applies the framing to the engineer's actual tables, and proactively surfaces denormalization as the practical design implication — the exact chain of reasoning the resource is designed to produce. Beginner clarity is particularly strong: the engineer gets a plain-English mental model with no jargon left unexplained.

The one material gap is the absence of the production-stack callout. The resource explicitly connects denormalization to Parquet file format behavior (why copying columns is cheap on MinIO/Iceberg) and to Trino's distributed query execution (why JOINs are expensive — network shuffles between workers). The answer gives the compression rationale ("Parquet compresses repeated values cheaply") but does not name Trino's shuffle cost as the primary motivation. An engineer who later reads about Trino JOINs will need to re-learn the connection.

## Resource gap
No new resource gap identified for this specific question. The existing `resources/09-lakehouse-schema-design.md` covers the answer accurately and the responder reproduced it correctly. The persistent beginner-clarity gap from earlier iterations (inline glosses for "grain", "SCD", "shuffle") is not triggered by this question, which stayed at the introductory level. The forward-reference to denormalization added at the end of the "Why keep them separate?" subsection (Iter 6 Q4 recommendation) appears to be working — the responder surfaced denormalization without being explicitly prompted by the question.
