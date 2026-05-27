# Score: Iteration 17, Question 1

**Date**: 2026-05-24
**Phase**: Final
**Question**: We added a new column `plan_tier` to our Postgres events table. It shows in our app but analytics still shows NULL — even for recent events with real values. Why?
**Rubric topics**: Postgres-to-Iceberg ingestion; Schema evolution in the pipeline

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.75 | Root cause correctly identified: Spark JDBC job doesn't read plan_tier → Iceberg gets NULLs. Two distinct fixes correctly distinguished: (1) full-refresh (createOrReplace) — update Spark SELECT, redeploy; (2) incremental (append) — ALTER TABLE ADD COLUMN first, then update Spark SELECT. Critically correct: explains WHY running ALTER TABLE ADD COLUMN alone won't fix full-refresh (next createOrReplace drops and rebuilds from DataFrame schema). Pre-flight schema-diff check is accurate bonus content. |
| Beginner clarity | 4.75 | Excellent. Opening "The Problem" paragraph correctly names the Spark layer as the failure point before any jargon. Two-scenario structure (createOrReplace vs append) is the right organization for this question. "Immediate Actions" with numbered steps is highly actionable. |
| Practical applicability | 4.75 | Correctly references production pipeline (Spark JDBC → Iceberg). The "sneaky bug that wastes debugging time" callout for full-refresh is exactly the content that prevents real production incidents. Pre-flight check is directly usable. |
| Completeness | 4.75 | Covers root cause, two ingestion patterns with different fixes, why the wrong fix doesn't work, pre-flight prevention, and immediate actions. Minor gap: doesn't mention that `ALTER TABLE ADD COLUMN` on Iceberg is metadata-only and instant (relevant context for engineers worried about downtime). |
| **Average** | **4.75** | |

---

## What the answer got right

1. Root cause: Spark job doesn't include plan_tier in its JDBC read — correct and the key insight.
2. Full-refresh pattern: ALTER TABLE won't stick across createOrReplace() cycles — correct and commonly missed.
3. Incremental pattern: ALTER TABLE first (Iceberg side), then update Spark job — correct two-step sequence.
4. Why old rows show NULL (Parquet files before schema change don't have the column, Iceberg fills NULL automatically) — correct.
5. Pre-flight schema-diff check is a practical prevention mechanism.

## What the answer missed

1. No mention that Iceberg ADD COLUMN is metadata-only (milliseconds, no lock) — relevant reassurance for engineers worried about the ALTER TABLE step.

---

## Engine labeling check

The answer uses `df.writeTo("iceberg.analytics.events").createOrReplace()` — Spark write API, correctly used in Spark context. No CALL statements without engine labels. Clean.

## Topic score updates

**Postgres-to-Iceberg ingestion**
- Prior: avg 3.694 across 9 questions
- This answer: 4.75 (10th angle — schema evolution / new column in Spark job)
- New running avg: (33.246 + 4.75) / 10 = **3.800** across 10 questions
- Status: PASSED (improved from 3.694)
