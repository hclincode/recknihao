# Judge Feedback — Iter 332

Date: 2026-05-27
Phase: extended
Topics: Postgres-to-Iceberg ingestion / offset.flush.interval.ms delivery gap (Q1) + Iceberg table maintenance / $history vs $snapshots (Q2)

---

## Q1 — offset.flush.interval.ms At-Least-Once Delivery Gap

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All five claims verified: offset.flush.interval.ms default 60s correct; duplicate window is time-based not event-count; LSN guard is canonical idempotency pattern; pre-MERGE ROW_NUMBER() dedup required; no fabricated APIs or behaviors. |
| Beginner clarity | 4.5 | Strong concrete examples (100 events/sec × 30s = 3,000 duplicates). "Worst case" framing for crash just before flush is excellent. Minor gap: LSN, WAL, and micro-batch are jargon not glossed for true beginners. |
| Practical applicability | 5 | Runnable MERGE SQL with LSN guard, ROW_NUMBER() window dedup code, and flush interval tuning advice all actionable. |
| Completeness | 4.75 | Covers: what the duplicate window is, whether MERGE INTO protects, both edge cases (LSN guard + batch dedup), how to reduce the window. Minor gap: no mention of Kafka's `auto.commit.interval.ms` distinction from `offset.flush.interval.ms`, or source-vs-sink commit nuance. |
| **Average** | **4.8125** | **PASS** |

### What Worked
- Time-based vs event-count-based framing: "A burst of 100,000 events in one second followed by 59 seconds of silence still creates only one offset commit window" — this is the key insight that prevents miscalculation.
- Both required protections surfaced: LSN guard in MERGE AND pre-MERGE batch dedup. Both are required; answer correctly treats them as mandatory.
- "Without the LSN guard, stale duplicates can silently overwrite correct newer values" — identifies the concrete failure mode, not just "bad things happen."
- Storage cost framing: "8 bytes per row — cheap insurance."

### What Missed
- LSN, WAL, micro-batch glossed inline but not defined — a true beginner may not follow.
- No mention of `auto.commit.interval.ms` vs `offset.flush.interval.ms` distinction (Kafka consumer offset vs Kafka Connect worker offset are different settings).
- No explicit production stack anchoring (this stack uses Kafka Connect + Debezium + Spark + Iceberg 1.5.2 on-prem k8s).

### Technical Accuracy (verified)
1. `offset.flush.interval.ms` default 60,000 ms — CORRECT
2. Duplicate window is time-based — CORRECT
3. LSN guard `s.source_lsn > t.source_lsn` is canonical idempotency pattern — CORRECT
4. Pre-MERGE ROW_NUMBER() dedup required for correct MERGE — CORRECT (Iceberg MERGE non-idempotency per apache/iceberg #11248)
5. No fabricated APIs or behaviors — CLEAN

### Rubric Update
- Postgres-to-Iceberg ingestion: prior avg 4.496 across 117 questions → (4.496 × 117 + 4.8125) / 118 = 530.8445 / 118 = **4.499 across 118 questions**. Status: **PASSED** (mild upward drift).

---

## Q2 — $history vs $snapshots for Time-Travel Queries

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All five verification points confirmed: $history has `made_current_at`; $snapshots has `committed_at`, `operation`, `parent_id`; `FOR VERSION AS OF <snapshot_id>` is correct Trino time-travel syntax; $history tracks current-snapshot lineage not all snapshots; both are valid Trino Iceberg metadata tables. |
| Beginner clarity | 5 | Rollback timeline (1:45/1:50/1:51/2pm) makes the distinction concrete and unambiguous. Decision matrix at the end covers all use cases. |
| Practical applicability | 5 | Two-step SQL (find snapshot_id from $history, then FOR VERSION AS OF) is copy-pasteable and correct. Includes proper `"events$history"` quoting. |
| Completeness | 4.5 | Covers: key difference, when to use each, how to query. Minor gaps: no mention of `is_current_ancestor` column in $history; `FOR TIMESTAMP AS OF` as one-shot alternative not mentioned (would let engineer skip the two-step query). |
| **Average** | **4.875** | **PASS** |

### What Worked
- Direct answer to the question: "Use $history, not $snapshots" — no hedging.
- Rollback example is the perfect illustration: $history shows Snapshot B becoming current at 1:51 via rollback; $snapshots would leave you guessing which was live at 2pm.
- Decision matrix distinguishes the two tables across four real use cases — engineers can use this as a reference.
- Correct two-step query pattern with proper double-quoting of `$history` table name.

### What Missed
- `is_current_ancestor` column in $history not mentioned (useful for "is this snapshot still in the live chain or has it been orphaned by a rollback?").
- `FOR TIMESTAMP AS OF` time-travel syntax not mentioned — this would let the engineer skip the two-step query entirely (`SELECT * FROM our_events FOR TIMESTAMP AS OF TIMESTAMP '2026-05-26 14:00:00'`). The resource documents this but the answer went with the two-step approach which requires reading $history first.

### Technical Accuracy (verified)
1. $history has `made_current_at` column — CORRECT
2. $snapshots has `committed_at`, `operation`, `parent_id` — CORRECT
3. `FOR VERSION AS OF <snapshot_id>` is correct Trino time-travel syntax — CORRECT
4. $history tracks which snapshot was current (not all snapshots ever created) — CORRECT
5. Both $history and $snapshots are valid Trino Iceberg metadata tables — CORRECT

### Rubric Update
- Iceberg table maintenance: prior avg 4.568 across 27 questions → (4.568 × 27 + 4.875) / 28 = 128.211 / 28 = **4.579 across 28 questions**. Status: **PASSED** (recovering from iter330 drop).

---

## Iter 332 Summary

**Iter 332 average: (4.8125 + 4.875) / 2 = 4.844 — PASS** ✓ (Q1 PASS / Q2 PASS)

### Notable
- Q1 4.8125: CDC delivery gap — at-least-once window framing is exactly right (time-based not event-count). Both required protections (LSN guard + pre-MERGE dedup) surfaced and required. Strong iteration.
- Q2 4.875: $history vs $snapshots — near-perfect. Rollback example clicked immediately for judges. Three perfect dimension scores. Minor gap on `FOR TIMESTAMP AS OF` shortcut.

### Resource fixes applied this iteration
None needed.

### Suggested focus for Iter 333
- **Multi-tenant analytics** (4.479/127, lowest): probe OPA policy bundle data.json partition structure — how to organize tenant data within data.json for scalable per-tenant policy evaluation. Or probe Trino session properties for per-tenant query resource limits (`query.max-memory-per-node`, `query.max-execution-time`).
- **Postgres-to-Iceberg ingestion** (4.499/118): probe the snapshot-row null LSN case in CDC dedup (identified in iter329 as a gap, never directly probed): when `op = 'r'` (snapshot row), source.lsn is null and the LSN guard `500 > NULL` evaluates as NULL (safe but unexplained).
- **Iceberg table maintenance** (4.579/28, recovering): probe `FOR TIMESTAMP AS OF` as a shortcut for the two-step $history query (gap identified in iter332 Q2).
