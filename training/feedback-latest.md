# Judge Feedback — Iter 333

Date: 2026-05-27
Phase: extended
Topics: Multi-tenant analytics / Trino resource groups per-tenant limits (Q1) + Postgres-to-Iceberg / CDC snapshot-row null LSN fix (Q2)

---

## Q1 — Trino Resource Groups for Per-Tenant Query Limits

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All five claims verified: softMemoryLimit/hardConcurrencyLimit/maxQueued are exact official property names; two-file config correct; `resource-groups.configuration-manager=file` correct; system.runtime.queries has resource_group_id; coordinator restart required for file-based config. Selector key `"user"` correctly used (not `"userRegex"` — a known trap). |
| Beginner clarity | 4.5 | "Lanes on a highway" analogy maps cleanly. JWT-username → selector → group chain explained. Minor gap: selector top-to-bottom evaluation order not explained — a beginner might not know first-match-wins. |
| Practical applicability | 5 | JSON config is runnable as-is. Live incident playbook (kill_query first, then config push + restart) is operational nuance separating useful answer from textbook. DB-backed hot-reload alternative mentioned. |
| Completeness | 4.5 | Covers: how resource groups work, three limit types, config files, selector routing, production notes. Missing: time limits (`query_max_run_time`, `query_max_execution_time`) despite question asking "memory OR time"; no per-query node-level memory cap (`query_max_memory_per_node`); no selector ordering caveat. |
| **Average** | **4.75** | **PASS** |

### What Worked
- Zero fabrications — JSON config uses exact Trino property names and is copy-pasteable.
- Correct selector key `"user"` (not `"userRegex"`) — a common trap in resource groups config.
- Live-incident playbook: kill runaway query first, then deploy config. This is the operationally correct sequence.
- DB-backed configuration manager mentioned as hot-reload alternative without fabricating properties.
- `system.runtime.queries.resource_group_id` diagnostic query — correct and actionable.

### What Missed
- **Time limits not mentioned**: engineer explicitly asked "memory OR time" — `query_max_run_time` (per-query max) and `query_max_execution_time` at the resource group level are the answer. These were in the question but not in the answer.
- **`query_max_memory_per_node`**: group-level `softMemoryLimit` caps total group memory but a single query can still hog a single node; the per-query per-node cap is defense-in-depth.
- **Selector evaluation order**: selectors are evaluated top-to-bottom, first match wins — a beginner with 10 selectors might put a catch-all selector first and wonder why specific rules don't fire.

### Technical Accuracy (verified)
1. softMemoryLimit, hardConcurrencyLimit, maxQueued — CORRECT (exact official property names)
2. Two-file setup (resource-groups.properties + resource-groups.json) — CORRECT
3. `resource-groups.configuration-manager=file` — CORRECT
4. system.runtime.queries has resource_group_id column — CORRECT (added Trino 0.206)
5. File-based config requires coordinator restart — CORRECT

### Rubric Update
- Multi-tenant analytics: prior avg 4.479 across 127 questions → (4.479 × 127 + 4.75) / 128 = 573.583 / 128 = **4.481 across 128 questions**. Status: **PASSED** (mild upward drift).

---

## Q2 — CDC Initial Snapshot Rows Have Null source_lsn — and the MERGE Fix

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All five verification points confirmed: Debezium snapshot rows have null source.lsn (no WAL position); `500 > NULL` evaluates to NULL in SQL three-valued logic; `t.source_lsn IS NULL OR s.source_lsn > t.source_lsn` is the correct null-safe idempotency guard; null LSN means "pre-WAL snapshot row"; test procedure is valid. |
| Beginner clarity | 5 | Step-by-step NULL evaluation trace (1→2→3→4→5, evaluates to NULL, NULL is falsy, UPDATE doesn't fire, silent drop) is exemplary beginner pedagogy. Concrete `500 > NULL = NULL` makes three-valued logic click without jargon. |
| Practical applicability | 5 | Corrected MERGE SQL with `t.source_lsn IS NULL OR s.source_lsn > t.source_lsn` is copy-pasteable. Bootstrap pattern `lit(None).cast("long")` is production-correct. Test procedure (insert before Debezium, update after) is a falsification test. |
| Completeness | 5 | Covers all four expected areas: is null LSN expected, why it breaks MERGE, the fix, how to test. No gaps. |
| **Average** | **5.00** | **PERFECT PASS** |

### What Worked
- Everything. Tight scope, all claims verified, perfect pedagogy, runnable code.
- "Null LSN means never been updated by CDC" — the semantic label for null makes future debugging easier.
- Test procedure is particularly valuable: tells the engineer exactly how to catch this class of bug in CI.

### What Missed
- None. Tightly scoped to exactly what the engineer asked.

### Technical Accuracy (verified)
1. Debezium snapshot rows have null source.lsn — CORRECT (Debezium PostgreSQL connector docs)
2. `500 > NULL` evaluates to NULL in SQL — CORRECT (three-valued logic)
3. `t.source_lsn IS NULL OR s.source_lsn > t.source_lsn` is correct null-safe guard — CORRECT
4. Null LSN means "pre-WAL snapshot row, never updated by CDC" — CORRECT
5. Test procedure (insert pre-snapshot, update post-streaming, verify in Iceberg) — VALID

### Rubric Update
- Postgres-to-Iceberg ingestion: prior avg 4.499 across 118 questions → (4.499 × 118 + 5.00) / 119 = 535.882 / 119 = **4.503 across 119 questions**. Status: **PASSED** (upward drift).

---

## Iter 333 Summary

**Iter 333 average: (4.75 + 5.00) / 2 = 4.875 — PASS** ✓ (Q1 PASS / Q2 PERFECT PASS)

### Notable
- Q1 4.75: Resource groups — technically clean, operationally complete. Minor gap on time limits (engineer asked "memory OR time"). Selector eval order not mentioned.
- Q2 5.00: Snapshot null LSN — perfect score. The null LSN gap from iter329/iter332 has now been addressed directly and answered perfectly.

### Resource fixes applied this iteration
None needed.

### Suggested focus for Iter 334
- **Multi-tenant analytics** (4.481/128): probe time-based query limits — `query_max_run_time` and `query_max_execution_time` at the resource group level (gap from iter333 Q1). Or probe `query_max_memory_per_node` as per-query node-level defense.
- **Iceberg table maintenance** (4.579/28): probe `FOR TIMESTAMP AS OF` as a one-step alternative to the two-step $history query (gap from iter332 Q2).
- **Postgres-to-Iceberg ingestion** (4.503/119, recovering): consider probing full-refresh pattern vs incremental vs CDC decision tree — when to use each approach.
