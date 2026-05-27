# Judge Feedback — Iter 337

Date: 2026-05-27
Phase: extended
Topics: Iceberg table maintenance / expire_snapshots vs remove_orphan_files distinction and scheduling order (Q1) + Postgres-to-Iceberg / deleting orphaned rows from Iceberg after EXCEPT detection (Q2)

---

## Q1 — expire_snapshots vs remove_orphan_files (PASS)

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3.5 | Order, orphan-file definition, 7d Trino floor, and example syntax are correct. BUT the central framing that `expire_snapshots` is "metadata-only" and that files "become eligible for deletion" (without being deleted) is wrong. Per Trino and Iceberg docs, `expire_snapshots` removes both expired snapshot metadata AND physically deletes data files exclusively referenced by those expired snapshots. `remove_orphan_files` handles a different class: files that were never in any snapshot at all. Also internally inconsistent: states "3 days" as the default (Iceberg Spark default) then says Trino enforces 7d floor without clarifying that Trino's default IS 7d, not 3d. |
| Beginner clarity | 4.5 | Clear structure, plain-language analogies (snapshot A vs B), concrete failure scenarios for orphan files, explicit ordering guidance with code. |
| Practical applicability | 4.5 | Engineer gets exact Trino syntax, scheduling cadence, ordering guidance, and maintenance-window suggestion. Trino 467 7d floor correctly called out. |
| Completeness | 4.0 | Covers what each procedure does, why both are needed, order, scheduling, prod constraints. Missing: (a) safety reason orphan removal needs generous threshold (concurrent in-flight writes); (b) `remove_orphan_files` is expensive (full directory listing of MinIO) so weekly cadence is appropriate; (c) the `dry_run` Spark-only preview option. |
| **Average** | **4.125** | **PASS** |

### What Worked
- Correct ordering (expire_snapshots → remove_orphan_files) matches official guidance.
- Correct identification of orphan file sources (mid-write crashes, failed commits, abandoned compaction temp files).
- Correctly flagged Trino 467's 7-day floor for both procedures.
- Trino `ALTER TABLE ... EXECUTE` syntax is correct.
- Sunday 3 AM maintenance window suggestion is sensible.
- Clear pedagogical structure.

### What Missed
1. **`expire_snapshots` is NOT metadata-only** — Per Trino docs: "The expire_snapshots command removes all snapshots and all related metadata AND data files." It physically deletes data files no longer referenced by any live snapshot. The answer said "files stay put until you explicitly tell Iceberg to delete them" — wrong. expire_snapshots tells Iceberg to delete them.
2. **The two classes of garbage were conflated** — The correct distinction:
   - Class 1 (expire_snapshots): files that WERE in snapshots, now expired → expire_snapshots deletes them
   - Class 2 (remove_orphan_files): files NEVER in any snapshot (failed writes) → expire_snapshots can't find them; remove_orphan_files does full directory scan
3. **3-day Spark default vs 7-day Trino default not cleanly separated** — On the production stack (Trino), the default is 7d, not 3d.

### Resource Fix Applied
- resources/17-iceberg-table-maintenance.md:
  1. Replaced "become eligible for deletion" at line 375 with explicit statement that `expire_snapshots` physically deletes unreferenced data files (S3 DELETE calls)
  2. Added CRITICAL DISTINCTION callout explaining Class 1 (expire_snapshots) vs Class 2 (remove_orphan_files) garbage
  3. Fixed line 271 which incorrectly said old files become "eligible for cleanup by remove_orphan_files" — corrected to say expire_snapshots physically deletes them itself

### Technical Accuracy (verified)
- expire_snapshots physically deletes data files no longer referenced — CORRECT per trino.io: "removes all snapshots and all related metadata and data files"
- remove_orphan_files handles files never in any snapshot — CORRECT per iceberg.apache.org maintenance docs
- Order: expire_snapshots → remove_orphan_files — CORRECT per official guidance
- Trino 467 7d floor for both procedures — CORRECT

### Rubric Update
- Iceberg table maintenance: prior avg 4.594/29 → (4.594 × 29 + 4.125) / 30 = 137.351 / 30 = **4.578 across 30 questions**. Status: **PASSED** (minor drop; resource framing error corrected).

---

## Q2 — Deleting Orphaned Rows from Iceberg After EXCEPT Detection (PASS)

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | DELETE → compact → expire_snapshots three-step chain verified correct. 7-day Trino floor accurate. Engine labels clean (Spark vs Trino). Cross-catalog EXCEPT in DELETE subquery is supported. Minor: expire_snapshots is not the sole physical-cleanup step — `remove_orphan_files` is the documented complement for files outside the snapshot graph. |
| Beginner clarity | 4.5 | Three numbered steps with "what happens / what doesn't happen" framing. Postgres analogy acknowledged. "Why all three required" with skip-step consequences is a strong teaching device. Transient slow-query window explained. |
| Practical applicability | 4.5 | Runnable Spark and Trino paths both shown. Cross-catalog DELETE FROM ... WHERE id IN (SELECT ... EXCEPT SELECT ...) directly answers the stuck-point. Missing: batching guidance for large ID lists and cross-catalog subquery perf warning. |
| Completeness | 4.0 | Covers DELETE → compact → expire lifecycle. Missing: (a) `remove_orphan_files` as 4th step; (b) batching for large ID lists (>10K); (c) cross-catalog subquery perf caveat (materialized ID list is safer); (d) partition-scoped optimize guidance; (e) EXCEPT-generated ID list is a moving target if new rows ingested between EXCEPT and DELETE. |
| **Average** | **4.375** | **PASS** |

### What Worked
- Correctly identified that DELETE alone does not free storage — multi-step sequence required.
- Clean Spark-vs-Trino separation with engine labels.
- 7-day retention floor for Trino's expire_snapshots correctly called out.
- "Skip step X consequences" framing turns procedure into causal reasoning.
- Acknowledges transient query slowdown between DELETE and compaction.
- DELETE SQL shows cross-catalog EXCEPT inline, directly answering the stuck-point.

### What Missed
1. `remove_orphan_files` not mentioned — documented maintenance order is expire → orphan → manifests; expire_snapshots doesn't catch all garbage.
2. No batching guidance for large reconciliation deletes (1M IDs → huge position-delete files).
3. No warning about cross-catalog DELETE subquery perf (re-evaluates postgres side at delete-plan time; safer to materialize ID list first).
4. `ALTER TABLE ... EXECUTE optimize` without WHERE clause rewrites entire table — partition-scoped optimize is much cheaper.
5. EXCEPT ID list is a moving target if rows were ingested between the EXCEPT and DELETE.

### Resource Fix Applied
None required. Resources/13 and resources/17 already cover the full pattern. Gaps are responder completeness.

### Rubric Update
- Postgres-to-Iceberg ingestion: prior avg 4.501/121 → (4.501 × 121 + 4.375) / 122 = 548.996 / 122 = **4.500 across 122 questions**. Status: **PASSED** (stable).

---

## Iter 337 Summary

**Iter 337 average: (4.125 + 4.375) / 2 = 4.25 — PASS** ✓

### Notable
- Q1 4.125: expire_snapshots framing error — resources/17 had misleading "become eligible for deletion" language that the responder amplified into a full "metadata-only" claim. Fixed immediately with CRITICAL DISTINCTION callout.
- Q2 4.375: DELETE orphaned rows lifecycle — correct three-step sequence with both Spark/Trino paths. Missed remove_orphan_files as 4th step and batching guidance.

### Resource fixes applied this iteration
- **resources/17-iceberg-table-maintenance.md**: Corrected expire_snapshots description (physically deletes unreferenced data files, not just metadata); added CRITICAL DISTINCTION callout for Class 1 vs Class 2 garbage; fixed line 271 confusing phrasing.

### Suggested focus for Iter 338
- **Iceberg table maintenance** (4.578/30, just dropped): Probe the corrected expire_snapshots distinction — ask specifically whether expire_snapshots or remove_orphan_files handles files from crashed write jobs. Verify the fix held.
- **Multi-tenant analytics** (4.461/131): Consider probing OPA session property override blocking with `SetSystemSessionProperty` action name explicitly.
- **Postgres-to-Iceberg ingestion** (4.500/122): Probe partition-scoped optimize or the batching guidance for large reconciliation deletes.
