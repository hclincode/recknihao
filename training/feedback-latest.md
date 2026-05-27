# Judge Feedback — Iter 317

Date: 2026-05-27
Phase: extended
Topics: Mixed column-masking-uri + batch-column-masking-uri footgun (Q1) + Debezium heartbeat.action.query for low-traffic databases (Q2)

---

## Q1 — Column masking stopped working after adding batch masking endpoint

### Score

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.75 | Core claims verified: `batch-column-masking-uri` overrides `column-masking-uri` when both set (exact docs quote confirmed); `batchColumnMasks` Rego rule name (plural) correct; response shape array with `viewExpression` + `index` verified; `input.action.filterResources[i]` path correct. Minor: silent fail-open behavior asserted confidently but not explicitly documented in Trino OPA docs — it's the observed behavior (undefined Rego rule = empty OPA result = no mask). Answer should soften to "in practice" or recommend checking OPA decision logs to confirm. |
| Beginner clarity | 4.5 | Diagnosis-first framing, side-by-side comparison table, Rego snippet with annotations, CI detection SQL. Minor: "Rego rule" / "OPA policy code" not defined in plain terms for beginners who configured OPA via copy-paste. |
| Practical applicability | 5.0 | Two clear fix paths (migrate to batch or revert to single), copy-pasteable Rego with correct response shape, CI SQL test to catch regressions. Fits production stack (Trino 467 + OPA per prod_info.md). |
| Completeness | 4.75 | Covers: root cause, silent failure, precedence interaction, both response-shape differences, two fix options, CI detection, full truth table. Missing: no mention of checking OPA/Trino decision logs to confirm which endpoint is being called; no coordinator restart reminder for `opa.policy.*` config changes. |
| **Average** | **4.75** | **PASS** |

### What Worked
- Precedence diagnosis ("batch overrides single when both set") is the exact root cause and was verified against official Trino docs quote
- Side-by-side table (endpoint / rule name / response shape / cost) is the right mental model
- `batchColumnMasks contains mask if { ... }` Rego is syntactically correct and matches official Trino example structure
- CI detection query turns a one-time fix into a regression guard
- Five-row truth table enumerates all configuration states

### What Missed
- Silent-failure claim asserted as documented behavior, not confirmed. Should recommend enabling `opa.log-requests=true` / `opa.log-responses=true` for diagnostic confirmation
- No coordinator restart reminder — `opa.policy.*` config changes require Trino coordinator restart
- No version note: batch column masking landed ~Trino 448 (PR #21997); prod is 467 so available, but one sentence confirms it

### Technical Accuracy (verified)
All claims verified against Trino 481 OPA docs. `batch-column-masking-uri` precedence: exact quote confirmed — "If `opa.policy.batch-column-masking-uri` is set it overrides the value of `opa.policy.column-masking-uri`."

### Rubric Update
- Multi-tenant analytics: prior avg 4.476 across 115 questions → (4.476 × 115 + 4.75) / 116 = **4.478 across 116 questions**. Status: PASSED.

---

## Q2 — Debezium heartbeat not reducing replication slot lag on low-traffic database

### Score

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | All core claims verified. `heartbeat.interval.ms` emits Kafka heartbeat events (does NOT advance Postgres slot LSN alone). `heartbeat.action.query` generates a WAL write on the monitored DB that flows through logical decoding, advancing `confirmed_flush_lsn`. Publication-inclusion requirement for filtered publications confirmed. `ON CONFLICT DO UPDATE` single-row upsert pattern confirmed. `confirmed_flush_lsn` as the key column confirmed. |
| Beginner clarity | 4.5 | One-sentence diagnosis, three-part decomposition, runnable SQL per diagnostic step. Minor: "publication" concept introduced functionally but `CREATE PUBLICATION` not linked back to; beginners may not know what a publication is. |
| Practical applicability | 5.0 | Exact `CREATE TABLE`, `GRANT`, `ALTER PUBLICATION`, JSON connector snippet, four sequential diagnostic SQL checks. "Most likely cause" section reads like an on-call pointer. Stack-compatible (on-prem k8s + Postgres + Debezium). |
| Completeness | 4.5 | Covers: heartbeat.interval.ms vs heartbeat.action.query distinction, publication requirement, single-row constraint, connector config, four diagnostic steps. Missing: `publication.autocreate.mode=filtered` interaction; cross-database WAL sharing explanation (why low-traffic DBs in multi-DB clusters are specifically affected); `REPLICA IDENTITY` requirement for UPDATE events. |
| **Average** | **4.75** | **PASS** |

### What Worked
- Precise distinction: `heartbeat.interval.ms` advances Kafka offsets only; `heartbeat.action.query` generates WAL write that advances `confirmed_flush_lsn`
- Three-part decomposition (table → publication → connector config) maps 1:1 to the three things engineers forget
- `CHECK (id = 1)` single-row constraint with 2,880 rows/day growth calculation — real production detail
- Diagnostic SQL sequenced to falsify each hypothesis
- "Most likely cause" section provides a direct on-call pointer

### What Missed
- `publication.autocreate.mode=filtered` interaction not mentioned — when Debezium auto-creates a filtered publication, heartbeat table must be in `table.include.list` or manually added (now added to resources/13)
- Cross-database WAL sharing not explained — this is why low-traffic DBs in a multi-DB cluster accumulate WAL even without Debezium failure (now added to resources/13)
- `REPLICA IDENTITY` requirement for UPDATE events (PK = DEFAULT works; otherwise need FULL)

### Technical Accuracy (verified)
All claims verified against Debezium stable docs, Confluent CDC docs, Gunnar Morling's LSN blog, DBAGlobe heartbeat benchmark. No factual errors detected.

### Rubric Update
- Postgres-to-Iceberg ingestion: prior avg 4.488 across 108 questions → (4.488 × 108 + 4.75) / 109 = **4.490 across 109 questions**. Status: PASSED.

---

## Iter 317 Summary

**Iter 317 average: 4.75 — PASS** ✓

### Notable
- Q1 4.75: Mixed endpoint footgun correctly diagnosed with exact precedence rule from Trino docs; coordinator restart note missing
- Q2 4.75: heartbeat.action.query distinction from heartbeat.interval.ms correct and verified; publication.autocreate.mode footgun and cross-database WAL sharing gaps

### Resource fixes applied this iteration
1. **resources/05-multi-tenant-analytics.md** — Added exact Trino docs precedence quote for `batch-column-masking-uri` overriding `column-masking-uri`; added coordinator restart note for `opa.policy.*` changes
2. **resources/13-postgres-to-iceberg-ingestion.md** — Added `publication.autocreate.mode=filtered` interaction callout; added cross-database WAL sharing explanation

### Suggested focus for Iter 318
- "Multi-tenant analytics" (4.478/116 — probe OPA row-filter performance at scale: Rego evaluation latency under high-concurrency, policy caching, bundle loading)
- "Postgres-to-Iceberg ingestion" (4.490/109 — probe schema evolution mid-CDC-pipeline: ADD COLUMN in Postgres, how Debezium handles schema registry updates, Iceberg schema evolution via ADD COLUMN)
- "Storage sizing" (4.521/6 — probe time-travel storage costs or partition-level sizing)
- "Real-time vs batch" (4.771/6 — probe Trino read-side effects of high-frequency streaming commits / HMS lock contention)
