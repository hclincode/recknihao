# Iter102-Q2 — Judge Evaluation

**Date**: 2026-05-25
**Question topic**: Multi-tenant analytics — making cross-tenant aggregation queries fast without breaking per-tenant isolation on a tenant-partitioned Iceberg events table.
**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter102-q2.md`

---

## Verdict: PASS (4.75)

Strong, stack-appropriate answer that walks the engineer through 4 distinct options with clear trade-offs and a concrete recommendation. One real technical error in the partition-order discussion (Option 2) costs Technical Accuracy a point; everything else is at or near the ceiling.

## Scores

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 4 | `$files`, `$partitions`, bucket caveat, metadata-only aggregation, Spark INSERT…SELECT…GROUP BY, OPA-independence all verified correct. Bug: claim that tenant-first partition order forces "Acme's events in May" to scan "Acme's entire partition (all days) then filter by date in the engine" is wrong — Iceberg performs partition pruning on any partition field regardless of declaration order. |
| Beginner clarity | 5 | Sets up the "why slow" framing concretely (80 tenants × N days). Each option labeled and explained without jargon. SQL is annotated. |
| Practical applicability | 5 | Targets the real stack: Trino + Iceberg + Spark + MinIO + OPA. Final recommendation is unambiguous: check partition spec, build `daily_event_rollup`, keep customer queries on base table. |
| Completeness | 5 | Diagnosis + 4 options + isolation discussion + final action plan. Both halves of the question (faster cross-tenant, preserved isolation) answered. |
| **Average** | **4.75** | |

## Verified-correct list

- `$files` exposes per-file `record_count`, `file_size_in_bytes`, and a `partition` struct whose subfields match identity-partition columns (`partition.tenant_id` works for identity-partitioned tables). Confirmed via Trino Iceberg connector docs and PR #26746 ("Fix $files partition column construction") plus Spark Iceberg docs.
- `$partitions` table has columns `partition`, `record_count`, `file_count`, `total_size` per Trino 481 docs (same shape in Trino 467).
- Metadata-only-aggregation claim: aggregating `record_count` from `$files`/`$partitions` reads only manifest metadata, not Parquet data files. Iceberg spec confirms record counts are stored in manifest entries.
- Bucket caveat: `bucket(tenant_id, N)` stores a 0..N-1 integer in the partition struct, not the original tenant_id. Correct per Iceberg spec.
- `INSERT INTO … SELECT … GROUP BY` against Iceberg from Spark is standard syntax.
- OPA-based authorization is independent of physical partition layout. Correct in framing.
- Pre-aggregated rollup table approach is the standard answer for this problem.

## Issues

### Real bug (Option 2 — partition-order claim)

The answer states:
> Switching from `ARRAY['day(occurred_at)', 'tenant_id']` to `ARRAY['tenant_id', 'day(occurred_at)']` (tenant-first) would improve cross-tenant sequential scans slightly, but breaks the per-tenant customer dashboard optimization — a per-tenant query like "Acme's events in May" would now scan Acme's entire partition (all days) then filter by date in the engine.

This is incorrect. Iceberg's partition pruning evaluates predicates against all partition fields independently of declaration order. A query `WHERE tenant_id = 'acme' AND occurred_at BETWEEN '2026-05-01' AND '2026-05-31'` would still prune by `day(occurred_at)` whether day is first or second in the partition spec. What partition order actually affects:

- **Write distribution / file clustering** (files sort within a partition by the leading field).
- **Manifest organization** (manifest entries grouped by leading field).
- **Small-file behavior** (tenant-first creates per-tenant directories with all dates inside; day-first creates per-day directories with all tenants inside — affects compaction and small-file pressure).

The conclusion ("don't reorder for this use case") is still defensible — day-first is usually right for SaaS events because it keeps daily compaction simple and avoids per-tenant small-file explosion — but the *reasoning* given (lost date pruning) is wrong and would mislead an engineer who later debates partition-order changes.

### Minor practical gap (rollup job idempotency)

The nightly Spark job uses `INSERT INTO daily_event_rollup … WHERE event_ts >= CURRENT_TIMESTAMP - INTERVAL '1' DAY`. Re-running the job or late-arriving events would produce duplicate aggregated rows. Should mention either:
- `INSERT OVERWRITE` of the target partition (`event_date`)
- `MERGE INTO` keyed on (event_date, tenant_id, event_type)
- Or at minimum note that the job assumes single daily execution with no replay.

### Minor — Spark vs Trino SQL dialect

The rollup SQL uses `INTERVAL '1' DAY` and `CURRENT_TIMESTAMP` which work in both engines, but the example doesn't say which engine runs it. Production stack uses Spark for ingestion — clarifying "run from Spark, scheduled by your orchestrator (Airflow/k8s CronJob)" would tighten the recommendation.

## Strengths

- Diagnosis-first structure: the "why slow" section frames the problem before jumping to solutions.
- Concrete numbers (80 tenants, "80× more files than a single-tenant query").
- The `$files` and `$partitions` paths are an excellent "free win" suggestion that most beginners would never discover — and the bucket caveat is the exact gotcha that would trip up a SaaS engineer using `bucket(tenant_id, N)`.
- Option 4 (separate Trino cluster) correctly labeled as overkill — shows judgment, not a kitchen-sink answer.
- Final isolation section explicitly says "authorization layer, independent of partition layout" — addresses the engineer's anxiety about breaking per-tenant guarantees.
- Recommendation block ends with a 3-step action list, not just abstract advice.

## Gaps

- Partition-order reasoning bug (see above).
- No rollup-job idempotency mention.
- Doesn't mention that `$partitions` only reflects the *current* partition spec (known Trino limitation per issue #12323) — minor edge case if the table has had partition evolution.

## Resource fix recommendations

1. **Multi-tenant analytics resource** (or partition-design resource): Add an explicit subsection clarifying that **Iceberg partition pruning works on any partition field independent of declaration order**. The choice of partition order affects write clustering, manifest organization, and small-file behavior — NOT pruning capability. This bug appeared in a 4.75 answer; without the fix it will recur and cost more points.
2. **Pre-aggregated rollup pattern**: Resource should include an idempotent template (`MERGE INTO` or partition-overwrite) alongside the simple `INSERT INTO` form, with a one-line note "use MERGE/OVERWRITE if the job may be re-run or late events arrive."
3. **`$files` / `$partitions` metadata-only queries**: This is a high-value beginner shortcut that should be promoted in the multi-tenant resource explicitly — with the bucket-vs-identity caveat called out as a callout box.

## Topic state update

**Multi-tenant analytics: isolating customer data in SaaS**
- Prior: avg 4.441 across 97 questions.
- New score: 4.75.
- New avg: (4.441 × 97 + 4.75) / 98 = **4.444** across 98 questions.
- Status: PASSED (well above 3.5 threshold).
