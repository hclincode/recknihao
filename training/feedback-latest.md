# Feedback — Iter 306 (Extended phase)

Date: 2026-05-27
Topics: When Postgres is enough vs OLAP (Q1) + CDC: Debezium→Kafka→Iceberg for updates and deletes (Q2)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | When to add OLAP: profiling Postgres first, tuning ladder, decision thresholds, migration to Iceberg+Trino | **4.9** | PASS |
| Q2 | CDC ingestion: WAL+Debezium, op/before/after events, MERGE INTO for UPDATE/DELETE, CoW vs MoR, hourly batch first | **4.875** | PASS |

**Iter 306 average: 4.888 — PASS** ✓

**Topic updates**:
- When to add an OLAP layer: 4.480/9 → **4.522/10 questions** (PASSED — improving)
- Postgres-to-Iceberg ingestion: 4.480/102 → **4.484/103 questions** (PASSED — stable)

---

## No resource fixes needed

Both answers technically accurate and verified against official docs. No resource corrections required before iter307.

---

## What worked

### Q1 — When to add OLAP (4.9)
1. Profiling-first approach: `log_min_duration_statement` + `EXPLAIN ANALYZE` before any warehouse recommendation
2. EXPLAIN ANALYZE plan-node interpretation table (Seq Scan / Bitmap Index Scan / Sort / Nested Loop) accurate and beginner-friendly
3. Tuning ladder ordered by impact-vs-effort: read replica → partial indexes → materialized views → composite indexes → PgBouncer
4. Correctly redirects from "Snowflake" to the actual production stack (MinIO + Iceberg + Trino + Spark)
5. Concrete decision thresholds: >10M rows for Seq Scan red flag, >50M rows for size problem, >1.5s after tuning, 2+ source systems
6. Three-node decision tree + full checklist + red flags = clear flowchart for an oncall engineer
7. Shows concrete PySpark migration snippet with `df.write.format("iceberg")` — answers "what does moving mean" practically
8. `$0 fix first` mentality closing summary

### Q2 — CDC ingestion (4.875)
1. Correctly explains Debezium reads the Postgres WAL via logical replication, never tables directly
2. Concrete JSON event sample showing op/before/after — all op codes (c/u/d) verified accurate
3. UPDATE handling: MERGE INTO by primary key with WHEN MATCHED UPDATE + WHEN NOT MATCHED INSERT — correct SQL
4. DELETE handling: MERGE INTO with WHEN MATCHED THEN DELETE using op="d" and before image — correct
5. All three Postgres prerequisites named and explained: `wal_level = logical`, `REPLICA IDENTITY FULL` (with correct rationale — default only logs PK columns), `pg_create_logical_replication_slot` with pgoutput
6. CoW vs MoR section: file-rewrite mechanics, delete-file mechanics, 5–30% read penalty, >1,000 UPDATEs/micro-batch decision rule, correct `write.delete.mode`/`write.update.mode`/`write.merge.mode` property names, hourly compaction
7. Honest "start with hourly batch first" recommendation — directly addresses 18-hour-stale pain with a 10x simpler fix before introducing Kafka+Debezium
8. 2–4 week stabilization timeline estimate sets realistic expectations

---

## Minor gaps (not errors, not resource fixes needed)

### Q1
- `REFRESH MATERIALIZED VIEW CONCURRENTLY` requires a UNIQUE index on the view — not mentioned; engineer copy-pasting will get an error
- `pg_stat_statements` extension not mentioned — standard tool for finding which 5 queries account for 80% of dashboard time
- `work_mem` / `shared_buffers` tuning not mentioned — often explains "Sort: 512MB+" memory pressure visible in EXPLAIN output

### Q2
- No mention of Debezium `r` op code (snapshot read events emitted during initial snapshot) — engineer will see these on day one
- No mention of replication slot WAL bloat risk — if Debezium goes down, the slot pins WAL and Postgres disk fills up (#1 production incident; should mention heartbeat config and slot monitoring)
- No mention of tombstone events (null-value Kafka messages after delete) and Kafka log-compaction interaction
- Schema drift mentioned as a tradeoff but no concrete pointer to Iceberg's `ALTER TABLE ADD COLUMN` as the analytics-side primitive

---

## Suggested iter307 angles

1. **approx_percentile for p99 latency dashboards** — when `approx_percentile` is appropriate vs exact percentile, multi-percentile syntax `approx_percentile(col, ARRAY[0.5, 0.95, 0.99])`, accuracy trade-offs
2. **Replication slot WAL bloat** — the #1 Debezium production incident; how to monitor, heartbeat config, `max_slot_wal_keep_size`, slot drop-and-replay procedure
3. **JSONB ingestion patterns** — promoting vs keeping as VARCHAR blob, `json_extract_scalar` in Trino vs `get_json_object` in PySpark, file-skipping limitation on JSON predicates
4. **Column-oriented storage deep dive** — how Parquet encodes data physically (row groups, column chunks, dictionary encoding), why predicate pushdown works at the file level
