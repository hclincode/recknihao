# Score: Iteration 18, Question 1

**Date**: 2026-05-24
**Phase**: Final
**Question**: PMs want near-real-time dashboards. Someone mentioned CDC / change data capture. What is it and how does it differ from our nightly batch? Is it harder to set up?
**Rubric topics**: Postgres-to-Iceberg ingestion (CDC pattern); Real-time vs batch analytics trade-offs

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.75 | CDC pipeline (WAL → Debezium → Kafka → Spark Structured Streaming → Iceberg) is accurate. Exactly-once semantics challenge is correct. Small files math (2880 files/day at 30s interval) is correct. Recommendation to try hourly micro-batching before CDC is the right guidance. Real CDC use cases (fraud detection, live counters, compliance) are accurate. |
| Beginner clarity | 4.75 | "Daily snapshot vs pipe" metaphor lands immediately. Three-tier table (nightly/hourly/CDC) with complexity column is the right pedagogical tool. "Push back on real-time" and the diagnostic questions are highly practical. |
| Practical applicability | 4.75 | On-prem Kubernetes stack correctly referenced. Hourly Spark micro-batch as the pragmatic intermediate step is exactly right for the production environment. "Add CDC only when a specific business metric genuinely demands it" is the correct operational philosophy. |
| Completeness | 4.75 | Covers CDC mechanics, pipeline components, 3x complexity assessment, small-files implication, diagnostic questions, when CDC is/isn't justified, practical recommendation. Minor gap: doesn't mention that Kafka needs to be deployed (if not already running) — adds even more ops complexity if starting from scratch. |
| **Average** | **4.75** | |

---

## What the answer got right

1. CDC pipeline (WAL → Debezium → Kafka → Spark Structured Streaming → Iceberg) — correct and complete.
2. Exactly-once semantics is hard — correct operational reality.
3. Small-files problem with streaming — correctly identified, correct math.
4. Recommend hourly Spark micro-batch first — the right intermediate step.
5. "Push back on real-time" with diagnostic questions — excellent practical framing.
6. Engine labeling: no CALL statements without Spark labels. Clean.

## What the answer missed

1. Kafka isn't running by default on the production stack — deploying Kafka is itself a significant operational task not acknowledged.
2. No mention of the DLQ (dead letter queue) pattern for handling Debezium parse errors.

## Topic score updates

**Postgres-to-Iceberg ingestion (CDC pattern)**
- Prior: avg 3.958 across 12 questions
- This answer: 4.75 (13th angle — CDC vs batch)
- Running avg contribution: (47.496 + 4.75) / 13 = **4.019** across 13 questions

**Real-time vs batch analytics trade-offs**
- Prior: avg 4.833 across 3 questions
- This answer: 4.75 (4th angle — CDC freshness tier)
- New running avg: (14.499 + 4.75) / 4 = **4.812** across 4 questions
- Status: PASSED (stable)
