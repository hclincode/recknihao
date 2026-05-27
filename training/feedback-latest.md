# Judge Feedback — Iter 341

Date: 2026-05-27
Phase: extended
Topics: Postgres-to-Iceberg ingestion / lag-buffer calibration (Q1) + Multi-tenant analytics / query_max_memory vs softMemoryLimit (Q2)

---

## Q1 — Lag-Buffer Calibration for Incremental Postgres Sync (STRONG PASS)

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | All core claims verified. `pg_stat_replication.replay_lag` is the correct column. MERGE INTO dedup pattern is correct. 15-30 min default is reasonable for healthy Postgres replicas. P99 × 2 as sizing methodology is industry-standard. Reference table (< 5 min → 15 min, 5-15 min → 30 min, etc.) matches resources/13 calibration table exactly. |
| Beginner clarity | 4.0 | The "disappearing row" scenario and "re-read overlap" rationale are well explained. The code snippet is helpful. Gaps: "primary", "read replica", and "replication lag" are used without inline definitions — a true beginner might not know these Postgres concepts. |
| Practical applicability | 5.0 | Engineer has everything needed: the P99 × 2 sizing formula, the pg_stat_replication query to run, the reference table to look up their number, the code pattern. Actionable end-to-end. |
| Completeness | 4.0 | Covers: why rows go missing, why duplicates happen, how to size the buffer, how to apply it in code. Minor gaps: `writeTo(...).merge()` omits ON clause / primary key join condition (code may not run as-is); no mention of reading from primary vs replica as an alternative failure mode; no escape-hatch alternatives (hot_standby_feedback, LSN-based watermarks for sub-5-min tolerance). |
| **Average** | **4.50** | **STRONG PASS** |

### What Worked
- Correctly explains BOTH symptoms (missing rows AND duplicates) and traces them to different root causes.
- P99 × 2 sizing recipe is correct and actionable.
- `pg_stat_replication.replay_lag` is the right column to query.
- Reference table matches the canonical calibration table in resources/13.
- MERGE INTO requirement correctly called out as the fix for duplicates.
- Resources/13 lag-buffer content (lines 245-268) correctly surfaced after multiple iterations of miss.

### What Missed
1. **`writeTo(...).merge()` missing ON clause** — Spark Iceberg MERGE INTO requires a join condition specifying which column(s) to match on. The code snippet as written is incomplete and may not run correctly.
2. **Primary vs replica failure modes not distinguished** — reading from replica (the common case) has the lag issue; reading from primary avoids it but adds load. Useful to note.
3. **No mention of `xmin`/LSN-based watermarks** — for sub-5-min lag tolerance use cases, LSN-based approaches avoid the replica lag problem entirely.
4. **Beginner-hostile terminology** — "primary," "read replica," and "replication lag" used without definition.

### Resource Fix Applied
None needed. Resources/13 already has comprehensive lag-buffer calibration content. This was a responder retrieval gap (confirmed by teacher pre-iter check), now closed.

### Rubric Update
- Postgres-to-Iceberg ingestion: prior avg 4.500/122 → (4.500 × 122 + 4.50) / 123 = 553.50 / 123 = **4.500 across 123 questions**. Status: **PASSED** (stable; lag-buffer calibration gap finally closed).

---

## Q2 — query_max_memory vs softMemoryLimit Enforcement (STRONG PASS)

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | All Trino field names verified against trino.io docs. query_max_memory IS a session property overridable by SET SESSION. softMemoryLimit in resource groups IS admission-control enforcement. query.max-memory IS the cluster-wide per-query ceiling. SetSystemSessionProperty IS the correct OPA action name. Minor inaccuracy: answer implies softMemoryLimit "kills" queries — it is actually admission control (queues/rejects new queries), not a mid-flight killer. |
| Beginner clarity | 4.5 | 3-row comparison table (query_max_memory / softMemoryLimit / query.max-memory) resolves the confusion directly. "Suggested default, not an enforced ceiling" framing is clear. Code snippet for resource-groups.json is concrete. Minor gap: "admission control" concept not explained — engineer may not know what queuing means for their runaway query. |
| Practical applicability | 5.0 | Engineer can immediately act: switch to softMemoryLimit in resource groups with the provided JSON snippet. Whitelist caveat for OPA option included. The "which problem are you solving?" framing (per-tier aggregate vs per-query enforcement) is practically useful. |
| Completeness | 4.5 | Covers: bypass mechanism, all three memory knobs, correct recommendation (softMemoryLimit), OPA option for session property enforcement. Key gap: doesn't clarify that softMemoryLimit is admission control — it queues new queries from the group but does NOT kill the in-flight runaway query. For the engineer's specific situation (query already ran and used too much memory), the answer that would have stopped it is query.max-memory (per-query hard ceiling), not softMemoryLimit (aggregate group limit). This framing distinction is missing. |
| **Average** | **4.625** | **STRONG PASS** |

### What Worked
- Correctly identifies query_max_memory as a default not a ceiling — direct answer to the engineer's confusion.
- 3-row comparison table (query_max_memory / softMemoryLimit / query.max-memory) is clear and complete.
- Steers to the right solution: softMemoryLimit in resource groups.
- SetSystemSessionProperty named correctly for the 4th consecutive question.
- Resources/05 query_max_memory fix from teacher pre-iter confirmed working immediately.

### What Missed
1. **softMemoryLimit is admission control, not a mid-flight killer** — the engineer's runaway query was already running. softMemoryLimit queues NEW queries when the group is over budget; it doesn't kill in-flight queries. The knob that would have killed the runaway mid-flight is `query.max-memory`. This distinction matters for the engineer's "why didn't it get killed" question.
2. **Per-query vs per-group enforcement not explicitly named** — `softMemoryLimit` is aggregate (all free-tier queries together); `query.max-memory` is per-query. Naming this would help the engineer pick the right lever.
3. **No mention of `query.max-memory-per-node`** — for per-worker defense-in-depth, this property exists but isn't in the answer.

### Resource Fix Applied
Consider adding to resources/05: explicit note that `softMemoryLimit` is admission control (queues/rejects new queries, does not kill in-flight) vs `query.max-memory` (per-query ceiling, kills queries mid-flight). This distinction was the main gap in iter341 Q2.

### Rubric Update
- Multi-tenant analytics: prior avg 4.447/134 → (4.447 × 134 + 4.625) / 135 = 600.523 / 135 = **4.448 across 135 questions**. Status: **PASSED** (recovering upward; query_max_memory vs softMemoryLimit distinction correctly explained on first attempt after resources/05 fix).

---

## Iter 341 Summary

**Iter 341 average: (4.50 + 4.625) / 2 = 4.5625 — STRONG PASS** ✓

### Notable
- Q1 4.50 STRONG PASS: Lag-buffer calibration gap finally closed after multiple iterations of miss. Resources/13 content surfaced correctly: P99 × 2 recipe, `pg_stat_replication.replay_lag`, reference table, MERGE INTO requirement.
- Q2 4.625 STRONG PASS: query_max_memory vs softMemoryLimit distinction correctly explained on first attempt after resources/05 pre-iter fix. SetSystemSessionProperty correctly named for 4th consecutive question. Key remaining gap: softMemoryLimit is admission control (queues, not kills), not a mid-flight query killer.

### Resource fixes applied this iteration
- **resources/05-multi-tenant-analytics.md** (teacher pre-iter fix): added query_max_memory vs softMemoryLimit vs query.max-memory 3-row comparison table. Fix confirmed holding immediately.
- No post-iteration fixes needed; remaining gaps are completeness/framing, not missing resource content.

### Suggested resource fix for iter342
- **resources/05**: Add note that softMemoryLimit is admission control (queues/rejects new queries when group budget is exceeded), not a mid-flight query killer. Distinguish from query.max-memory (per-query hard ceiling that can kill mid-flight). This distinction was the main completeness gap in iter341 Q2.

### Suggested focus for Iter 342
- **Multi-tenant analytics** (4.448/135): Probe the admission-control vs mid-flight-kill distinction — specifically "I want to kill a runaway query from a free-tier customer that's already running and consuming too much memory, which Trino lever does that?"
- **Postgres-to-Iceberg** (4.500/123): Probe the MERGE INTO ON clause / primary key join condition — the missing detail from iter341 Q1.
- **Iceberg table maintenance** (4.575/33): Consider probing the interaction between expire_snapshots min-retention floor and the same 7-day floor on remove_orphan_files — are both understood together?
