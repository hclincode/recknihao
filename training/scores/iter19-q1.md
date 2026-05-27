# Score: Iteration 19, Question 1

**Date**: 2026-05-24
**Phase**: Final (final iteration)
**Question**: We have events (append-only) and users (constantly updated) tables. Right now we do full reload of both every night. Teammate says switch events to incremental but keep users as full reload. Is that reasonable? How do I decide which tables use which pattern?
**Rubric topics**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.75 | All mechanics correct: append-only tables → incremental, small mutable dimensions → full refresh, large mutable dimensions → MERGE INTO. `overwritePartitions()` correctly recommended over `append()` for idempotency. `CALL iceberg.system.rollback_to_snapshot()` uses correct catalog name (`iceberg.system.*`). Watermark storage in MinIO JSON file is a standard approach. Running both patterns side by side is correctly assessed as safe since they write to different tables. Minor: answer names `append()` as used in the incremental pattern before immediately recommending `overwritePartitions()` — the transition between the two is slightly abrupt for a beginner. |
| Beginner clarity | 4.75 | Decision table (append-only vs mutable small vs mutable large vs static) is an excellent pedagogical tool. "Cardinality matters more than mutability" is the right framing. Concrete Postgres ADD COLUMN example for adding `updated_at` is actionable. Idempotency failure scenario (crash after append, before watermark update → duplicates) is explained clearly with numbered steps. |
| Practical applicability | 4.75 | Spark code examples are correct for the production stack (Spark + Iceberg 1.5.2 on Kubernetes). Scheduling guidance (2 AM for both jobs, 4 AM for compaction) is practical. `overwritePartitions()` with fixed batch_date is the correct production-ready pattern. Watermark stored as JSON in MinIO is the right choice for on-prem. |
| Completeness | 4.50 | All three sub-questions answered: (1) is the split reasonable — yes, with explanation; (2) decision criteria — covered with table; (3) is running both patterns dangerous — no, but scheduling matters. Minor gap: `createOrReplace()` not explicitly named as what they're currently using for full-refresh — a beginner might not connect "drop and recreate everything" in the question to `createOrReplace()` in the resources. Validation steps brief but present. |
| **Average** | **4.69** | |

---

## What the answer got right

1. Append-only → incremental, mutable small → full refresh, mutable large → MERGE INTO — correct branching rule.
2. `overwritePartitions()` over `append()` for idempotency — correctly explained with atomic/idempotent properties.
3. Running both patterns side by side is safe — correct, with the right caveat (different tables = no conflict).
4. Rollback via `CALL iceberg.system.rollback_to_snapshot()` — correct catalog name, not `spark_catalog.system.*`.
5. Watermark corruption recovery path — mentioned and correct.
6. Compaction needed after switching to incremental — correctly flagged.

## What the answer missed

1. `createOrReplace()` not named explicitly — the decision table names "full reload" without connecting it to the API the engineer is currently using.
2. Watermark corruption procedure could be more specific (how to manually set it if it drifts).

## Topic score updates

**Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling**
- Prior: avg 4.067 across 14 questions
- This answer: 4.69 (15th angle — full-refresh vs incremental decision criteria)
- Running avg: (4.067 × 14 + 4.69) / 15 = (56.938 + 4.69) / 15 = **4.108** across 15 questions
- Status: PASSED (solidly above 4.0)
