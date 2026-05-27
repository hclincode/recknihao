# Judge Feedback — Iter 310

Date: 2026-05-27
Phase: extended
Topics: CTAS / write-side exfiltration in multi-tenant Trino (Q1) + Postgres CDC replication slot WAL bloat (Q2)

---

## Q1 — CTAS / write-side exfiltration in multi-tenant Trino

### Score

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | CTAS write-side exfiltration is a real risk; `$files` does expose `file_path` (verified trino.io/docs/current/connector/iceberg.html). OPA can deny `CreateTable`/`CreateTableAsSelect` operations (verified trino.io OPA access control docs). MinIO IAM supports path-scoped policies. No false claims. |
| Beginner clarity | 4.0 | Risk explained step-by-step with a concrete example; the four-layer structure is easy to follow. Terms like "OPA Rego," "principal," "IAM," and "metadata table" used without short glosses — a SaaS engineer with no OLAP background will follow it but may need to look up `$files` and "Rego." |
| Practical applicability | 5.0 | Fits the prod stack (Trino + Iceberg + MinIO + OPA) precisely. Defers specific Rego rules to the external governance document (correct per prod_info.md). Provides a concrete CI test, P0 alert criterion, and explicit architectural choice (Option A vs B for MinIO credentials). |
| Completeness | 5.0 | Covers all four mitigation surfaces: write-path SQL deny, metadata-table deny, MinIO IAM scoping, audit/alerting. Includes defense-in-depth reasoning (what happens if rule #1 misfires). Mentions `$partitions`, `$snapshots`, `$manifests`. Minor: `$path` hidden column not explicitly called out; no mention that `INSERT INTO` presents the same risk as CTAS. |
| **Average** | **4.75** | **PASS** |

### What Worked
- Correctly framed CTAS-then-`$files` as the canonical write-side exfiltration path — the example query is exactly the attack a tenant would run
- Four-layer defense-in-depth model (write deny, metadata deny, MinIO IAM scoping, audit) is the industry-standard answer and each layer is independently meaningful
- Properly deferred specific OPA Rego rules to the external governance document — neither hand-waved nor over-prescribed
- Differentiated Option A (no tenant MinIO credentials, signed-URL export endpoint) from Option B (path-scoped IAM) — gives the engineer an architectural choice
- CI test and P0 alert criteria are concrete and runnable
- Closing checklist is a useful artifact the engineer can copy into a ticket

### What Missed
- The `$path` hidden column (a per-row hidden column that also returns the underlying file path) is not explicitly called out. The "deny `$`-suffix table" rule does not cover `SELECT "$path", * FROM acme_scratch.exfil` because `$path` is a hidden column, not a metadata table.
- `INSERT INTO ... SELECT` presents the same write-side exfiltration surface as CTAS — if the engineer's environment permits it for export, it needs the same OPA write-side denies
- Brief glosses for "Rego," "principal," and "IAM" would help beginner clarity without lengthening the answer much
- No explicit mention that CTAS-from-view (not from base table) is also a vector — if the tenant's view returns their rows, CTAS-from-view still materializes rows they can extract via MinIO

### Technical Accuracy
All verified:
- `$files` exposes `file_path`: confirmed in Trino Iceberg connector docs
- OPA can deny `CreateTableAsSelect`: confirmed via `input.action.operation` in OPA access control plugin
- MinIO IAM supports path-scoped policies: confirmed, MinIO PBAC follows AWS IAM syntax
- Metadata tables (`$files`, `$partitions`, `$snapshots`, `$manifests`): all exist as documented

### Rubric Update
- Multi-tenant analytics: prior avg 4.467 across 109 questions → (4.467 × 109 + 4.75) / 110 = **4.469 across 110 questions**. Status: PASSED.

---

## Q2 — Postgres CDC Replication Slot WAL Bloat

### Score

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | All major claims verified against official docs. Minor oversimplification of `wal_status` (omits `extended` and `unreserved` intermediate states). Heartbeat root-cause framing slightly imprecise. MERGE INTO syntax in Step 4 is pseudo-SQL with trailing WHERE after MERGE clauses — illustrative but not copy-pasteable. |
| Beginner clarity | 5.0 | The "post-it note" analogy for replication slots is excellent. Walks through what an LSN is, what happens when Debezium falls behind, and why the disk fills — all without assuming prior CDC knowledge. The "Monday morning" checklist closes the loop perfectly. |
| Practical applicability | 4.75 | Specific thresholds (50 GB warn, 150 GB crit, 5 min disconnect), concrete SQL queries, exact config properties, named runbook steps. Fits Postgres + Debezium + Iceberg stack cleanly. Small gap: MERGE step would need translation into Spark+JDBC form for the on-prem stack. |
| Completeness | 4.75 | Covers mechanism, monitoring queries, self-defense config, recovery runbook, and heartbeat safeguard — all four pillars. Could mention `safe_wal_size` column as the most direct "headroom" metric, and could acknowledge `unreserved` intermediate state for monitoring. |
| **Average** | **4.75** | **PASS** |

### What Worked
- "Post-it note" analogy for replication slots is exemplary — gives a mental model and technical anchor simultaneously
- Correctly frames that the CDC pipeline can take down the *application database*, not just analytics — elevates severity appropriately
- Three non-negotiables structure (monitor, self-defend, runbook) is easy to remember
- Recovery runbook is concrete and ordered: drop → recreate → restart with `snapshot.mode: never` → backfill via MERGE
- "Walk through it once on staging" guidance is operational wisdom beyond textbook answers
- Heartbeat section addresses a real second-order failure mode (idle monitored tables)
- Monday morning summary is actionable — five concrete tasks an engineer can execute this week

### What Missed
- `wal_status` enumeration is incomplete — official PG docs define four states: `reserved`, `extended`, `unreserved`, `lost`. The `unreserved` state is the "imminent danger, still recoverable" warning that gives the on-call window to act before invalidation.
- `safe_wal_size` column not mentioned — the most direct "how much headroom do I have" metric from `pg_replication_slots` when `max_slot_wal_keep_size` is set
- Heartbeat root-cause framing slightly off: the slot falls behind when *other* unrelated tables generate WAL while the monitored table is idle — Debezium has no events to acknowledge, so the flush LSN doesn't advance even though global WAL position moves
- MERGE INTO Step 4 is pseudo-SQL — trailing WHERE after MATCH clauses is not valid Spark/Iceberg MERGE syntax; an engineer copy-pasting this will hit a parse error
- No mention that `max_slot_wal_keep_size` requires Postgres 13+

### Technical Accuracy
Verified against postgresql.org docs, Debezium connector docs:
- `wal_status` states: `reserved`, `extended`, `unreserved`, `lost` — confirmed
- `max_slot_wal_keep_size` auto-invalidation at Postgres 13+ — confirmed
- `confirmed_flush_lsn` semantics — confirmed
- `heartbeat.interval.ms` and `heartbeat.action.query` Debezium properties — confirmed
- `snapshot.mode: never` — valid Debezium config to skip snapshot after slot recreation — confirmed
- `pg_drop_replication_slot` / `pg_create_logical_replication_slot` functions — confirmed

### Rubric Update
- Postgres-to-Iceberg ingestion: prior avg 4.487 across 104 questions → (4.487 × 104 + 4.75) / 105 = **4.490 across 105 questions**. Status: PASSED.

---

## Iter 310 Summary

**Iter 310 average: 4.75 — PASS** ✓

### Suggested focus for Iter 311
- `$path` hidden column as a metadata-table bypass not covered by `$`-suffix deny rules — multi-tenant security gap
- `wal_status: unreserved` as the actionable early-warning state before `lost` — Debezium monitoring completeness
- `safe_wal_size` column for direct replication slot headroom measurement
- MERGE INTO valid Spark SQL syntax for the backfill pattern (vs pseudo-SQL shown)
- OPA column masking / row-filter alternative at 500+ tenant scale (still untested after teacher added it to resources/05)
