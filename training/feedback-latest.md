# Judge Feedback — Iter 311

Date: 2026-05-27
Phase: extended
Topics: $path hidden column and metadata bypass vectors (Q1) + Postgres replication slot wal_status states and safe_wal_size (Q2)

---

## Q1 — $path hidden column and other metadata bypass vectors

### Score

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.75 | All five vectors are real and correctly described. `$path` hidden column verified against Trino Iceberg connector docs. `system.runtime.queries` exposure concern is real (non-admins see own queries by default, but explicit OPA deny is correct best practice). Direct MinIO bypass and DESCRIBE/SHOW vectors accurate. Minor: "OPA can inspect the column list in the query context" for `$path` denial is correct but doesn't name the `FilterColumns` operation explicitly. |
| Beginner clarity | 4.5 | Strong opening framing ("necessary but insufficient"). Each vector has a concrete SQL example or scenario. Numbered structure is scannable. The `SELECT "$path"` example is exactly what the engineer needs to see. Recommended Full Fix with priority tiers (non-negotiable vs risk-appetite) is excellent. Minor: "OPA principal" used without a one-liner refresher. |
| Practical applicability | 4.75 | Fits the production stack (OPA, Trino + Iceberg, MinIO). Names actual Trino access-control operations (`FilterCatalogs`) — verified accurate. Defers specific Rego rules to external governance doc (per prod_info.md). Five-item actionable checklist. |
| Completeness | 4.75 | Covers main bypass surfaces. Missing: (a) `$partition` and `$file_modified_time` hidden columns alongside `$path` — equally exposed, same defense; (b) `information_schema` as a distinct enumeration surface from `system` catalog; (c) `system.metadata.table_properties` which can expose Iceberg `location` property (MinIO path). OPA `FilterColumns` operation name not given. |
| **Average** | **4.69** | **PASS** |

### What Worked
- "Necessary but insufficient" framing sets correct expectations immediately
- Concrete `SELECT "$path"` SQL example — exactly the bypass the engineer needs to see
- Five-vector enumeration (system catalog, $path, MinIO, DESCRIBE/SHOW, statistical inference) — all real and ordered by severity
- Recommended Full Fix with priority tiers gives a credible ship plan
- Stack-aware language (OPA, MinIO, JWT principal, CTAS export) matching prod_info.md without inventing specific Rego rules
- Names actual Trino access-control operations (`FilterCatalogs`) rather than vague references

### What Missed
- `$partition` and `$file_modified_time` are equally hidden columns on Iceberg tables — a blocked tenant could pivot to these; should be grouped as "the hidden column family"
- `system.metadata.table_properties` returns the Iceberg `location` property (MinIO warehouse path) for any table the user can see — a specific high-leverage bypass that fits the question exactly
- `information_schema` is a distinct enumeration surface from the `system` catalog
- OPA `FilterColumns` operation not named — a senior engineer knows what to look for but a beginner won't

### Technical Accuracy
Verified:
- `$path`, `$partition`, `$file_modified_time` hidden columns: confirmed in Trino Iceberg connector docs
- OPA can deny specific column references via `FilterColumns`: confirmed in Trino OPA docs and issue tracker
- `FilterCatalogs` and metadata-listing events: confirmed in Trino access control docs
- `system.runtime.queries` non-admin access: OPA explicit deny is correct best practice even if defaults limit visibility

### Rubric Update
- Multi-tenant analytics: prior avg 4.469 across 110 questions → (4.469 × 110 + 4.69) / 111 = **4.471 across 111 questions**. Status: PASSED.

---

## Q2 — Postgres replication slot wal_status states and safe_wal_size

### Score

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 2.5 | Four `wal_status` states correctly named and ordered. But the answer makes a material factual error directly contradicting the user's question: claims "Postgres doesn't expose a direct 'bytes remaining before invalidation' column" — `safe_wal_size` is exactly that column (PG 13+), available in `pg_replication_slots`. Additionally, the headroom formula uses `confirmed_flush_lsn` where `restart_lsn` is the LSN that actually drives slot invalidation; with long-running transactions these diverge and the formula underestimates real slot pressure. |
| Beginner clarity | 4.5 | Plain-language framing ("yellow-flag territory", "page immediately"), well-structured alert tier table, clear runbook references. A SaaS engineer without Postgres internals background can follow it. |
| Practical applicability | 3.5 | Alert tiers and heartbeat config are concrete and actionable. But the missing `safe_wal_size` recommendation means the engineer builds a more brittle monitoring system (manual subtraction from a GUC instead of reading a server-computed column that auto-handles edge cases like NULL when slot is lost or when max_slot_wal_keep_size = -1). |
| Completeness | 3.5 | Covers states, alert tiers, and heartbeat. Misses `safe_wal_size` (the exact column the user asked about), `inactive_since` (PG 14+, useful for detecting stuck Debezium), and `invalidation_reason` (PG 16+, critical for post-mortem). No end-to-end lag monitoring tie-in with Iceberg snapshot age. |
| **Average** | **3.50** | **PASS (barely)** |

### What Worked
- Correctly identifies all four `wal_status` values in correct progression: reserved → extended → unreserved → lost
- Correctly answers the headline question: "is `lost` too late?" → yes, alert on `unreserved`
- Alert-tier table mixing byte thresholds, percentage thresholds, status flags, and `active = false` heuristic is what production monitoring needs
- Heartbeat section with working Debezium config snippet for idle-table coverage is real-world wisdom
- Correct nuance: don't rely solely on bytes thresholds because WAL generation rate spikes can skip past them

### What Missed (CRITICAL)
- **`safe_wal_size` column directly answers the user's question.** The user asked "is there a column that tells us exactly how much headroom we have left?" — the answer is YES: `pg_replication_slots.safe_wal_size` (PG 13+) is exactly that column. The answer incorrectly says this column doesn't exist.
- **`restart_lsn` vs `confirmed_flush_lsn`**: the bytes_behind formula should use `restart_lsn` (drives slot invalidation) not `confirmed_flush_lsn` (consumer acknowledgement). These diverge with long-running transactions.
- `inactive_since` (PG 14+) — direct timestamp for when Debezium disconnected, more useful than tracking `active = false` duration in monitoring
- `invalidation_reason` (PG 16+) — tells why slot was invalidated (wal_removed/rows_removed/wal_level_insufficient) for post-mortem
- No end-to-end monitoring tie-in: healthy Postgres slot with stuck Iceberg writer still causes CDC lag the user cares about

### Technical Accuracy
Verified from postgresql.org docs:
- `safe_wal_size` column EXISTS in `pg_replication_slots` since PG 13: "The number of bytes that can be written to WAL such that this slot is not in danger of getting in state 'lost'." NULL for lost slots and when max_slot_wal_keep_size = -1. The answer's claim that this column doesn't exist is incorrect.
- `restart_lsn` vs `confirmed_flush_lsn`: Gunnar Morling's authoritative post confirms `restart_lsn` determines WAL retention/invalidation, not `confirmed_flush_lsn`
- Four `wal_status` states: confirmed correct per postgresql.org docs
- Debezium heartbeat config: confirmed correct

Sources: postgresql.org/docs/current/view-pg-replication-slots.html, EDB "PostgreSQL 13: Don't let slots kill your primary", morling.dev "Confirmed Flush LSN vs. Restart LSN"

### Rubric Update
- Postgres-to-Iceberg ingestion: prior avg 4.490 across 105 questions → (4.490 × 105 + 3.50) / 106 = **4.481 across 106 questions**. Status: PASSED.

**Note**: This is a regression in score (3.50 vs. the prior 4.75 pattern) driven by a critical factual inaccuracy — directly denying a column that exists. Resources fixed (teacher pass): resources/13 now includes safe_wal_size, restart_lsn vs confirmed_flush_lsn, inactive_since, invalidation_reason. Resources/05 now includes the hidden column family ($path/$partition/$file_modified_time) and system.metadata.table_properties.

---

## Iter 311 Summary

**Iter 311 average: 4.095 — PASS** (Q1 4.69, Q2 3.50)

### Suggested focus for Iter 312
- `safe_wal_size` column directly — follow-up question on slot monitoring where responder must now demonstrate the corrected resource content
- `restart_lsn` vs `confirmed_flush_lsn` distinction — a targeted question to verify the fix landed
- Hidden column family ($path/$partition/$file_modified_time) probe — verify resources/05 fix
- OPA row-filter alternative at 200+ tenant scale — still not tested from a question angle
