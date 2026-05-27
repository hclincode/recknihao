# Score: Iteration 17, Question 4

**Date**: 2026-05-24
**Phase**: Final
**Question**: One enterprise customer needs 1-hour-stale analytics; all others are fine with 24-hour. How to handle different freshness SLAs on a single platform?
**Rubric topics**: Multi-tenant analytics; Real-time vs batch analytics trade-offs; Postgres-to-Iceberg ingestion

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.75 | Core pattern correct: two Spark jobs (hourly micro-batch + nightly batch) writing to the same Iceberg table, Trino views for tiered access. Watermark-based incremental ingestion for hourly job is correct. overwritePartitions() recommended for idempotency — correct and consistent with iter17 Q2. CALL statements wrapped in spark.sql() — correctly labeled as Spark. Compaction scheduled after both ingestions — correct ordering. Monitoring gotchas (watermark overflow, small files, late arrivals) are accurate. |
| Beginner clarity | 4.75 | "One table, tiered scheduling" concept is explained clearly before any code. Table comparing single-table vs separate pipelines is the right way to address the "why not just run two pipelines" concern. Kubernetes CronJob example grounds the concept in production reality. |
| Practical applicability | 4.75 | Addresses the exact scenario (on-prem Kubernetes, Spark, Iceberg, Trino). Concrete: two CronJob specs, watermark pattern, Trino view definitions. Monitoring section prevents the most common failure modes. |
| Completeness | 4.75 | Covers: tiered scheduling concept, incremental pattern, idempotency, view layer, scheduling, monitoring gotchas, and explicit comparison vs separate pipelines. Minor gap: doesn't address what happens when the hourly job and nightly job write to overlapping partitions (they use the same day partition — the hourly job writes "today" while the nightly writes "yesterday," so they don't overlap, but this isn't explicitly noted). |
| **Average** | **4.75** | |

---

## What the answer got right

1. Tiered scheduling (two jobs → one table) is the correct architecture for this scenario.
2. overwritePartitions() for idempotent hourly writes — correct, consistent with Q2.
3. Trino views with ingested_at filter for freshness tier enforcement — correct and elegant.
4. CALL wrapped in spark.sql() — engine-labeling fix from iter17 resources is working.
5. Monitoring section: watermark overflow, small files, late arrivals — all correct and practical.
6. Compaction scheduling after both ingestions — correct ordering.

## Engine labeling check ✓

All CALL statements appear inside `spark.sql(...)` calls, correctly indicating Spark execution. The iter17 resource fix is producing the desired behavior — this is the second answer this iteration correctly labeling Spark CALL syntax.

## Topic score updates

**Multi-tenant analytics**
- Prior after Q3 this iter: avg 4.003 across 14 questions
- This answer: 4.75 (15th angle — freshness SLA tiers)
- New running avg: (56.042 + 4.75) / 15 = **4.053** across 15 questions
- Status: PASSED (solidly above 4.0)

**Real-time vs batch analytics trade-offs**
- This answer exercises micro-batch vs batch trade-off
- Prior: avg 4.875 across 2 questions (strong topic)
- This answer: 4.75 (3rd angle)
- New running avg: (9.75 + 4.75) / 3 = **4.833** across 3 questions
- Status: PASSED (stable)

**Postgres-to-Iceberg ingestion**
- Prior after Q1+Q2 this iter: avg 3.886 across 11 questions
- This answer: 4.75 (12th angle — incremental watermark for hourly ingest)
- New running avg: (42.746 + 4.75) / 12 = **3.958** across 12 questions
- Status: PASSED (continuing to improve toward 4.0)
