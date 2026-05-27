# Iter 6 Q4 — Fact table vs dimension table: events vs users

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | Every claim is correct: fact = one row per event (append-only), dimension = one row per entity (small, slowly changing). The events/users assignment is accurate. The three "why separate" reasons (shape, mutation pattern, query pattern) all match the resource and are factually sound. The Iceberg/columnar storage closing statement is accurate. |
| Beginner clarity | 5 | Exceptionally clean for a beginner. Leads with a direct conceptual correction ("not about size"), uses the engineer's own table names immediately, and explains every concept inline ("enrich," "append-only," "broadcast to all workers"). No unexplained jargon — columnar storage and partition pruning appear only as a forward reference at the very end, not as prerequisites. The "rewrite billions of event rows" example makes the mutation problem concrete. |
| Practical applicability | 5 | Direct, unambiguous answer to the specific question: events = fact table, users = dimension table. The three-reason framework gives a decision rule applicable to any future table. The Postgres-to-Iceberg bridge is grounded in the prod stack. The engineer knows exactly how to categorize their tables and why the distinction matters operationally. |
| Completeness | 4 | Fully addresses the "is it just the biggest table?" misconception and the events/users assignment. However, the topic covers "fact tables, dimension tables, denormalization" — denormalization is not mentioned at all. A one-sentence bridge ("and in practice you'll copy dimension columns like plan_type into the fact table to avoid JOINs") would have completed the picture. Grain is also implicit but unnamed (same gap as Iter 3 Q1). No mention of tenant_id as a partition lever, which is relevant to this engineer's B2B SaaS setup. |
| **Average** | **4.75** | |

## Topic updated

**Topic:** Lakehouse schema design: fact tables, dimension tables, denormalization

- Prior avg: 4.25 over 1 question
- This answer score: 4.75
- New running avg: (4.25 + 4.75) / 2 = **4.50** across 2 questions
- Status: **PASSED** (avg 4.50 >= 3.5 threshold, 2 questions asked >= 2 required minimum)

## Key finding

The responder delivers a near-perfect beginner-facing explanation of fact vs dimension tables — clear framing, correct assignment of the engineer's specific tables, and a concrete mutation-cost example that makes the separation feel necessary rather than academic. The only material gap is that the full topic scope (including denormalization) is not addressed, leaving the "so where does plan_type go?" question unanswered until the engineer asks it separately.

## Resource gap

`resources/09-lakehouse-schema-design.md` — the existing resource covers denormalization well (lines 112–143), but the fact/dimension introduction section (lines 19–37) does not forward-reference denormalization. Add one sentence at the end of the "Why keep them separate?" subsection: "In practice, you'll often copy frequently-queried dimension columns (like plan_type or country) directly into the fact table to avoid JOINs entirely — see the Denormalization Rules section below." This primes engineers reading the intro to see fact/dimension/denormalization as one connected pattern rather than three separate ideas, and would prompt the responder to surface it when answering a conceptual question like this one.
