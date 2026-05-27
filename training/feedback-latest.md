# Judge Feedback — Iter 316

Date: 2026-05-27
Phase: extended
Topics: Postgres replication slot WAL bloat — Debezium CDC (Q1) + OPA decision log debugging for Trino access control (Q2)

---

## Q1 — Postgres replication slot WAL bloat

### Score

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.25 | All core mechanics correct: slot semantics, `max_slot_wal_keep_size`, `wal_status` lifecycle, `restart_lsn` vs `confirmed_flush_lsn`, `safe_wal_size`, heartbeat, `snapshot.mode: no_data`. **One concrete version error**: `inactive_since` is PG 17+, not PG 14+ as stated. (PG 14 added `conflicting`, PG 16 added `invalidation_reason`, PG 17 added `inactive_since`.) |
| Beginner clarity | 5.0 | Opens with "the #1 Debezium production incident" framing. Defines WAL and slot from first principles, uses concrete numbers (50 GB, 30 sec), explains root-cause chain in numbered steps, tells engineer exactly what each LSN column physically represents. Zero assumed OLAP knowledge. |
| Practical applicability | 5.0 | Four-item action list, exact `postgresql.conf` line, executable monitoring SQL with alert thresholds, two-statement recovery SQL, exact Debezium config line, explicit staging runbook walkthrough guidance. Fits on-prem k8s + Postgres + Debezium stack. |
| Completeness | 4.75 | Covers slot fundamentals, root-cause chain, three defenses (`max_slot_wal_keep_size`, monitoring, recovery runbook), heartbeats, recovery with `snapshot.mode: no_data`, gap-window backfill. Minor gaps: `invalidation_reason` (PG 16+) not mentioned for on-call triage; cross-database WAL accumulation case not covered; `heartbeat.action.query` for zero-traffic databases not mentioned. |
| **Average** | **4.75** | **PASS** |

### What Worked
- Three-part failure chain (acks → confirmed_flush_lsn advances → Postgres cleans WAL; freeze any link and WAL accumulates) is the clearest explanation of slot bloat
- "CDC dies, application stays up is almost always the right tradeoff" — exactly the framing needed to defend this design choice
- Dual-LSN explanation (`restart_lsn` for disk impact, `confirmed_flush_lsn` for consumer lag) correctly mapped to Postgres docs
- `safe_wal_size` as "most actionable single metric" is correct and verified against prometheus-community/postgres_exporter recommendations
- Heartbeat `30000 ms` matches Confluent's recommended starting value
- Recovery procedure: `snapshot.mode: no_data` + targeted backfill — correct and efficient (avoids multi-hour re-snapshot)

### What Missed
- **`inactive_since` version wrong** — tagged PG 14+, actually PG 17+ (fixed in resources/13)
- `invalidation_reason` (PG 16+) not mentioned — when `wal_status = 'lost'`, this column tells you why (`wal_removed`, `rows_removed`, etc.); first thing on-call should check
- Cross-database WAL accumulation: slot is per-database but WAL is per-cluster — a high-traffic sibling database generates WAL that accumulates against a slot on a quiet database even without Debezium failure
- `heartbeat.action.query` not mentioned — for zero-traffic databases, `heartbeat.interval.ms` alone does not advance the slot LSN; a write to the monitored database is needed

### Technical Accuracy (verified)
All claims verified against PostgreSQL docs, Gunnar Morling's restart_lsn/confirmed_flush_lsn blog, EDB PG 13 slot blog, Debezium connector docs, DBAGlobe heartbeat benchmark. Version error: `inactive_since` is PG 17+ per `pg_replication_slots` docs.

### Rubric Update
- Postgres-to-Iceberg ingestion: prior avg 4.486 across 107 questions → (4.486 × 107 + 4.75) / 108 = **4.488 across 108 questions**. Status: PASSED.

---

## Q2 — OPA decision log debugging for Trino access control

### Score

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.75 | All field paths verified correct against official Trino 481 OPA docs and OPA decision-log spec: `input.context.queryId`, `input.context.identity.user/groups`, `input.action.operation`, `input.action.filterResources`, `input.action.resource.table.catalogName/tableName`, `metrics.timer_rego_query_eval_ns` (exact key, correct — not `eval_ns`), `decision_id`. **Minor**: OPA YAML config example is functionally broken — `decision_logs` block missing `service: backend`, so remote service never receives logs (now fixed in resources/05). |
| Beginner clarity | 4.5 | Durability caveat as lead is the right framing. Step-by-step debugging recipe is well-sequenced. OpenSearch DSL example is concrete. Minor: operation-name casing (upper-camel in JSON vs lowercase in docs narrative) not explained; `pg_stat_activity` forensic cross-reference is off-stack for this production environment. |
| Practical applicability | 5.0 | Runnable DSL example, exact field paths, batched-uri noise reduction, two focused on-call dashboards with thresholds, three-way forensic cross-reference pattern. Engineer can start Monday morning. |
| Completeness | 4.75 | Covers: durability prerequisite, log structure, debugging recipe (queryId → operation → filterResources → decision_id), log shipping setup, exact JSON paths, batched-uri, on-call dashboards, analysis-time-only behavior. Missing: operation-name casing note; queryId join-key format spelled out; governance-doc cross-reference for "why" interpretation. |
| **Average** | **4.75** | **PASS** |

### What Worked
- All field paths (`input.context.queryId`, `input.action.filterResources`, `metrics.timer_rego_query_eval_ns`) verified correct
- Durability caveat as prerequisite — the most common reason decision-log debugging is impossible
- `opa.policy.batched-uri` → 1 log line for 50 tables is accurate and high-value
- Step-by-step recipe (queryId + user → operation → filterResources → decision_id) is exactly what on-call needs
- `metrics.timer_rego_query_eval_ns` specifically called out (not truncated `eval_ns`)

### What Missed
- **OPA YAML config broken** — missing `service: backend` in `decision_logs` block; as written ships console only (fixed in resources/05)
- Operation-name casing: Trino emits upper-camel (`SelectFromColumns`, `FilterTables`) in JSON but docs narrative uses lowercase; one-line note prevents confusion
- queryId join-key format not spelled out (`20250718_081710_03427_trino`) — explicit example helps when cross-referencing Trino event listener
- `pg_stat_activity` forensic reference is off-stack (on-prem Trino + Iceberg + MinIO, not Postgres federation)
- "OPA only at analysis time" blanket statement slightly imprecise: row-filter and column-mask Rego rules also evaluate at planning, and the universal "in-flight queries unaffected" claim holds for static auth but not for all dynamic auth configurations

### Technical Accuracy (verified)
All field paths verified against Trino 481 OPA docs and OPA decision-logs spec. Operation names verified. `metrics.timer_rego_query_eval_ns` confirmed exact key.

### Rubric Update
- Multi-tenant analytics: prior avg 4.473 across 114 questions → (4.473 × 114 + 4.75) / 115 = **4.476 across 115 questions**. Status: PASSED.

---

## Iter 316 Summary

**Iter 316 average: 4.75 — PASS** ✓

### Notable
- Q1 4.75: Replication slot WAL bloat answered with correct three-part failure chain and dual-LSN explanation; `inactive_since` version error (PG 14+ → PG 17+) caught and fixed in resources/13
- Q2 4.75: OPA decision log debugging answered with all field paths verified correct; broken YAML config (missing `service: backend`) caught and fixed in resources/05

### Resource fixes applied this iteration
1. **resources/13-postgres-to-iceberg-ingestion.md** — `inactive_since` version tag corrected from PG 14+ to PG 17+
2. **resources/05-multi-tenant-analytics.md** — OPA decision_logs YAML config fixed to include `service: backend` in the decision_logs block

### Suggested focus for Iter 317
- "Postgres-to-Iceberg ingestion" (4.488/108 — probe `invalidation_reason` (PG 16+) for on-call triage, or `heartbeat.action.query` for zero-traffic databases)
- "Multi-tenant analytics" (4.476/115 — probe the mixed endpoint config footgun: `batch-column-masking-uri` overrides `column-masking-uri` if both set)
- "Storage sizing" (4.521/6 — probe a different angle: retention math or time-travel storage cost)
- "Real-time vs batch" (4.771/6 — probe Trino read-side effects of high-frequency streaming commits / HMS lock contention)
