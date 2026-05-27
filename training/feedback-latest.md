# Feedback — Iter 295 (Extended phase)

Date: 2026-05-27
Topics: SCD Type 2 (plan history) + Iceberg partition design (day/bucket/identity)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | SCD Type 2: storing/querying slowly-changing plan column; dbt snapshots | **4.50** | PASS |
| Q2 | Partition design for 2B-row multi-tenant events: day vs bucket vs identity | **4.50** | PASS |

**Iter 295 average: 4.50 — PASS** ✓

**Topic updates**:
- Schema design for analytics: 4.50/3 → **4.50/4 questions** (PASSED — stable)
- Lakehouse schema design: 4.688/4 → **4.650/5 questions** (PASSED — stable)
- Iceberg partition design: 4.589/15 → **4.583/16 questions** (PASSED — stable)

---

## What worked

### Q1 — SCD Type 2 (4.50)
1. Short-answer + before/after row example — immediately shows what changes
2. OLTP-vs-OLAP framing for why nightly overwrite breaks history — connects to engineer's mental model
3. Three runnable SQL queries: point-in-time lookup, last-quarter overlap, current-only — all correct
4. Half-open interval for last-quarter overlap (`valid_from < end AND valid_to >= start`) — technically correct
5. Type 1 vs Type 2 decision table — immediately actionable

### Q2 — Partition design (4.50)
1. "Partition = file skipping" explained in one sentence — right abstraction for a beginner
2. Concrete math: 800 tenants × 365 days = 292K partitions, in Iceberg's comfort zone — shows the engineer can reason about limits
3. Metadata-only COUNT optimization for identity `tenant_id` partitioning — excellent practical detail, shows the trade-off of bucketing
4. Decision rule for when to switch to `bucket(tenant_id, 64)` — concrete threshold (1,000+ tenants or 80%+ skew)
5. Hidden partitioning explanation — clarifies that you write normal SQL and Iceberg does the pruning

---

## Resource fixes applied (iter 295)

**Bug 1 (Q1)**: Answer claimed `dbt_is_current` column — this column does not exist. dbt snapshot materialization emits: `dbt_valid_from`, `dbt_valid_to`, `dbt_is_deleted` (dbt 1.9+). Current records are identified by `dbt_valid_to IS NULL`. Also the snapshot block lacked the required `config()` block with `target_schema`, `unique_key`, `strategy`, and `check_cols`.

**Fix applied** to `resources/09-lakehouse-schema-design.md`:
- Replaced the one-liner dbt mention with a complete `{% snapshot %}` block including `config()`
- Listed actual dbt metadata columns (`dbt_valid_from`, `dbt_valid_to`, `dbt_is_deleted`)
- Added explicit note: "There is no `dbt_is_current` column" + correct query pattern (`WHERE dbt_valid_to IS NULL`)
- Added Spark `MERGE INTO` alternative for teams not using dbt

**Bug 2 (Q2)**: Answer said compaction must be done via Spark, failing to mention Trino-native compaction (`ALTER TABLE ... EXECUTE optimize`). Resource 10 lines 540–541 already correctly documented this. No resource change needed — the responder missed it in the resource.

---

## Suggested iter296 angles

1. **SQL OLAP best practices** — `TABLESAMPLE BERNOULLI` for cheap dashboard prototyping without a full scan; cost-effective exploration pattern
2. **Multi-tenant analytics** — harder angles: row-level security via Ranger policies, or cross-tenant SLA metrics (how do you report on p99 latency per tenant?)
3. **Postgres-to-Iceberg ingestion** — CDC deep dive (Debezium + Kafka → Spark → Iceberg) vs full-refresh tradeoffs; when to move from nightly snapshot to real-time CDC
4. **Real-time vs batch** — already PASSED at 4.812; reinforce with a concrete SaaS scenario (live dashboards for enterprise customers, latency SLAs)
