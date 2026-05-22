# Judge Evaluation Rubric

## Scoring dimensions (each 0–5)

| Dimension | Description |
|---|---|
| **Technical accuracy** | Is the OLAP/big data information factually correct? |
| **Beginner clarity** | Is it understandable with zero OLAP background? No unexplained jargon. |
| **Practical applicability** | Can the SaaS engineer act on this for their product? |
| **Completeness** | Does it fully address the question without overwhelming detail? |

**Pass threshold per topic**: average ≥ 3.5 across all dimensions, tested from at least 2 different question angles.

---

## Required topic checklist

Each topic must reach the pass threshold before the system can enter final phase.

| Topic | Status | Avg Score | Questions Asked |
|---|---|---|---|
| OLAP vs OLTP — difference and why it matters for SaaS | pending | 5.0 | 1 |
| What a data warehouse is and when a SaaS product needs one | pending | — | 0 |
| What a data lakehouse is and how it differs from a warehouse | pending | — | 0 |
| Column-oriented storage — what it is and why it's faster for analytics | pending | — | 0 |
| Common analytical query patterns: aggregations, funnels, cohort, time-series | pending | — | 0 |
| Schema design for analytics: denormalization, star schema basics | pending | — | 0 |
| When to add an OLAP layer vs staying on the transactional DB | pending | — | 0 |
| Multi-tenant analytics: isolating customer data in SaaS | pending | — | 0 |
| Popular tools overview: BigQuery, Snowflake, ClickHouse, DuckDB, Iceberg | pending | — | 0 |
| Real-time vs batch analytics trade-offs | pending | — | 0 |
| Cost considerations for analytical workloads at SaaS scale | pending | — | 0 |
| Query performance basics: partitioning, indexing strategy for analytics | pending | 5.0 | 1 |

---

## Score history

### Q1 — 2026-05-23
**Question**: Why does a GROUP BY / COUNT query slow down so much worse than a point-lookup as rows grow?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **5.0** |

**Topics updated**: OLAP vs OLTP (1 question, avg 5.0); Query performance basics (1 question, avg 5.0)
