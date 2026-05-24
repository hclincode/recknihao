# Feedback — Iteration 52 (Extended Phase)

**Date**: 2026-05-24
**Phase**: Extended (continuing until 2026-05-30 12:00 CST)
**Iteration average**: 4.50
**Status**: All 20 topics PASSED.

---

## Iteration 52 score summary

| Question | Topic(s) | Score |
|---|---|---|
| Q1 — Debezium CDC schema evolution: new column added to Postgres events table | Postgres-to-Iceberg ingestion | 4.25 |
| Q2 — Week-over-week WAU change using LAG() window function in Trino | Analytical query patterns on Iceberg+Trino | 4.75 |
| **Iteration average** | | **4.50** |

---

## Topic score updates after iteration 52

| Topic | Prior avg | Prior q | New avg | New q | Change |
|---|---|---|---|---|---|
| Postgres-to-Iceberg ingestion | 4.276 | 52 | 4.275 | 53 | −0.001 (Q1 at 4.25) |
| Analytical query patterns on Iceberg+Trino | 4.333 | 3 | 4.438 | 4 | +0.105 (Q2 at 4.75) |

Both topics remain PASSED.

---

## What went well

**Q2 scored 4.75 — LAG() window function fully covered.** First test of the LAG/LEAD novel angle. The responder correctly:
- Used `LAG(wau, 1) OVER (ORDER BY week_start)` with correct Trino syntax (verified against trino.io)
- Provided `NULLIF(..., 0)` for division-by-zero protection
- Explained `LAG()` in plain English ("look back 1 row in sorted order")
- Called out first-week NULL as expected/correct
- Mentioned `LEAD()` as the opposite
- Added production partition-pruning note with `WHERE occurred_at >= current_date - INTERVAL '13' WEEK`
- Included `ROW_NUMBER()` and `NTILE()` as bonus window functions

**Q1 operational sequence correct (4.25).** The responder got the most actionable parts right: `ALTER TABLE ADD COLUMN` in Iceberg before resuming the consumer; Iceberg ADD COLUMN is metadata-only; Debezium source connector does not need to be stopped; columns tracked by field ID (safe rename/reorder).

---

## Issues

### Q1 technical misattribution: schema registry ≠ DDL detection mechanism

The Q1 answer stated: "Debezium ... detects the DDL via a schema registry — either Confluent Schema Registry or Apicurio."

This is wrong. DDL detection happens through **WAL relation messages** — Postgres embeds the new table column layout in the next WAL record after an ALTER TABLE. The schema registry is for *serializing Kafka message payloads* (Avro/Protobuf), unrelated to DDL detection. An engineer who reads this answer will look for a schema registry config to enable DDL detection — it doesn't exist.

Additionally, the answer mentioned "`schema.evolution=basic` in Debezium 2.x" as if it's a source connector setting. It is actually a **Debezium Iceberg sink connector** setting; the Postgres source connector does not have this property. Engineers searching for it in the source connector docs won't find it.

**Fix applied**: `resources/13-postgres-to-iceberg-ingestion.md`
- Updated the CDC row in the schema evolution table to clarify `schema.evolution=basic` is a sink connector setting
- Added "### For CDC jobs (Pattern C)" subsection explaining:
  - WAL relation messages as the actual DDL detection mechanism (not schema registry)
  - Schema registry = Kafka payload serialization only; unrelated to DDL detection
  - `schema.evolution=basic` is on the Debezium Iceberg sink connector
  - Two order-of-operations paths: manually-managed consumer vs Debezium sink connector

### Q2 minor: "single pass" framing slightly imprecise

"Window functions avoid scanning the table twice" is correct in spirit, but the CTE still aggregates once and the window function runs over the small per-week result. The real benefit is code simplicity, not physical I/O reduction. Minor — doesn't affect usability.

### Recurring beginner clarity gap

Q1: WAL, logical replication slot, schema registry, schema evolution — appear without inline glosses. Q2: "window function" used before being defined. Persistent multi-iteration gap.

---

## Resource fixes applied in iter52

**HIGH priority — COMPLETED**: `resources/13-postgres-to-iceberg-ingestion.md`
- Fixed CDC row in schema evolution table: clarified `schema.evolution=basic` is on Debezium Iceberg sink connector (not source connector); updated "Fix" column to reflect correct order of operations
- Added "### For CDC jobs (Pattern C)" subsection with:
  - WAL relation messages as DDL detection mechanism
  - Schema registry separation (serialization only)
  - `schema.evolution=basic` attribution to sink connector
  - Two complete order-of-operations paths (manual vs automated)

---

## Weakest topics heading into iter53

| Topic | Avg | q |
|---|---|---|
| Multi-tenant analytics | 4.270 | 52 |
| Postgres-to-Iceberg ingestion | 4.275 | 53 |
| Storage sizing and growth estimation | 4.333 | 3 |
| Analytical query patterns on Iceberg+Trino | 4.438 | 4 |
| Iceberg partition design | 4.500 | 6 |

Novel angles for iter53:
- **Multi-tenant**: JWT claim → resource group selector mapping (JWT `sub` claim = selector match key); or OPA integration pattern for row-level data filtering
- **Postgres-to-Iceberg**: Post-fix validation — test CDC schema evolution again now that WAL-relation-message explanation is in the resource; or test a novel angle like handling a column TYPE CHANGE (INT → BIGINT) under CDC
- **Storage sizing**: cost-per-event formula (parquet_bytes_per_row × monthly_rows / 1e9); when to run rewrite_data_files to switch all existing files from Snappy to Zstd
- **Analytical patterns**: NTILE for percentile buckets (top quartile of tenants by WAU); RANK vs DENSE_RANK distinction
