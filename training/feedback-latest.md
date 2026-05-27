# Judge Feedback — Iter 325

Date: 2026-05-27
Phase: extended
Topics: Iceberg manifest cleanup / optimize_manifests on Trino 467 (Q1) + STRUCT vs flat columns for stable-schema JSONB (Q2)

---

## Q1 — Iceberg manifest cleanup and slow query planning on Trino 467

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | Every load-bearing claim verified. `optimize_manifests` confirmed added in Trino 470 (Feb 5, 2025) via PR #14821. Spark `CALL iceberg.system.rewrite_manifests(table => '...')` named-arg syntax matches official Iceberg Spark procedures docs. 7-day min-retention floor for both `expire_snapshots` and `remove_orphan_files` confirmed. Maintenance sequence (optimize → expire → orphan → manifests) matches resources/17 and canonical runbook order. No fabrications. |
| Beginner clarity | 5 | Opens with concrete plain-English definition of manifest files. "Trino must deserialize and scan all 50,000 before it can tell your query which data to read" makes the metadata-vs-data distinction clear without jargon. 50k manifests → 30s → <1s contrast is immediately intuitive. |
| Practical applicability | 5 | Engineer knows exactly what to run: immediate one-statement Spark fix, both CLI invocation methods, weekly schedule guidance paired with snapshot expiry, complete 4-step runbook with engine labels. Summary table maps each procedure to which engine on Trino 467. |
| Completeness | 5 | Covers: what manifest files are, why they slow planning not execution, what to actually run on Trino 467, whether it's a different Trino command or Spark. Bonus: 7-day floor proactively, Trino 470 upgrade path, ordering rationale for the full sequence. |
| **Average** | **5.00** | **PASS** |

### What Worked
- Version-gate precision: Trino 470 (Feb 2025) as the version introducing `optimize_manifests` — exact match against release notes.
- Engine routing unambiguous: every code block labeled, summary table makes "Spark not Trino" visible at a glance.
- Concrete numbers (50k manifests → 30s → <1s) give a testable expectation.
- Full 4-step maintenance sequence with correct ordering and ordering rationale.
- 7-day floor mentioned proactively with GDPR escape hatch (Spark bypasses floor).

### What Missed
- Minor: `optimize` shown without `WHERE` partition-scoped variant.
- Minor: no diagnostic query (`SELECT COUNT(*) FROM "events$manifests"`) to confirm manifest count before/after.
- Minor: `dry_run` is Spark-only for `remove_orphan_files` — step 3 treats it as a clean Trino call without this caveat.

### Technical Accuracy (verified)
All four verification asks pass. No fabrications. No version mismatches.

### Rubric Update
- Iceberg table maintenance: prior avg 4.561 across 22 questions → (4.561 × 22 + 5.00) / 23 = **4.580 across 23 questions**. Status: **PASSED**.

---

## Q2 — STRUCT vs flat columns for stable-schema JSONB

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3.5 | Most claims correct (STRUCT physical layout, per-field stats, `from_json`, `withField`, JSON-string drawbacks, dereference-pushdown caveats). One serious error: `ALTER TABLE ... MODIFY COLUMN metadata STRUCT<...>` is NOT valid Iceberg syntax. Correct form is `ALTER TABLE ... ADD COLUMN metadata.sso_enabled BOOLEAN` (dotted-path ADD COLUMN). Iceberg docs explicitly state "ALTER COLUMN is not used to update struct types; instead, use ADD COLUMN and DROP COLUMN." Engineer pasting the MODIFY COLUMN form would get a parser error. |
| Beginner clarity | 4.5 | Clear definitions, accessible language. Trade-off table excellent. Dot-notation, bracket-notation, and CAST AS JSON variants all shown. Minor: "dereference pushdown" feature name never used explicitly. |
| Practical applicability | 3.5 | Strong on the decision framework, hybrid pattern, recommendation, Spark code. Loses points because the schema-evolution DDL (most likely thing to copy-paste) contains invalid syntax — engineer would hit a syntax error on day one of evolving the schema. |
| Completeness | 4.5 | All three approaches covered, trade-off table, query performance scenarios with concrete numbers, both ingestion patterns, schema-evolution scenario, backfill, hybrid promotion, explicit verdict. Minor: no EXPLAIN snippet to verify pushdown fires. |
| **Average** | **4.00** | **PASS** |

### What Worked
- Clear three-way framing (flat / STRUCT / JSON string) with crisp pros/cons.
- Trade-off comparison table accurate at the cell level.
- Two correct PySpark ingestion patterns (`from_json` with explicit schema, `struct(col, col, ...)`) with "never auto-derive in prod" guardrail.
- Per-field min/max statistics claim for STRUCT verified against Iceberg spec.
- Honest treatment of Trino dereference pushdown ("more conservative on nested predicates") — matches PR #8129 and known Parquet caveats.
- Hybrid promotion pattern (one hot field flat + full STRUCT) is a real production recipe.
- Numerical query-performance scenarios (7/2000 vs 50/2000 vs 2000/2000 files) make the trade-off tangible.

### What Missed
- **DDL error**: `ALTER TABLE ... MODIFY COLUMN metadata STRUCT<...>` is not Iceberg syntax. Correct: `ALTER TABLE iceberg.analytics.events ADD COLUMN metadata.sso_enabled BOOLEAN`. This is the single most consequential error — a copy-paste trap on day one of schema evolution.
- No Trino syntax example for the dotted-path ADD COLUMN (engineer's main query engine is Trino 467).
- "Dereference pushdown" — the actual Trino feature name — never used; would help engineer search for follow-ups.
- No EXPLAIN snippet to verify nested predicate pushdown actually fires.

### Technical Accuracy (verified)
1. STRUCT stored as separate Parquet columns with per-field min/max — VERIFIED
2. `from_json(col, schema)` — VERIFIED
3. Trino 467 dereference pushdown with caveats — PARTIALLY VERIFIED (PR #8129, hedging is fair)
4. `withField` PySpark syntax — VERIFIED (Spark 3.1.1+)
5. `ALTER TABLE ... MODIFY COLUMN metadata STRUCT<...>` — **FALSE** — parser error on Iceberg

### Resource Fix Applied
resources/13 updated: added explicit STRUCT schema evolution callout with correct dotted-path `ADD COLUMN metadata.new_field TYPE` syntax and explicit note that `MODIFY COLUMN` is invalid for STRUCT field addition. See lines added after the decision table.

### Rubric Update
- Postgres-to-Iceberg ingestion: prior avg 4.494 across 114 questions → (4.494 × 114 + 4.00) / 115 = **4.490 across 115 questions**. Status: **PASSED** (slight downward drift from MODIFY COLUMN error; resource fix applied to prevent recurrence).

---

## Iter 325 Summary

**Iter 325 average: (5.00 + 4.00) / 2 = 4.50 — PASS** ✓ (Q1 PASS / Q2 PASS)

### Notable
- Q1 5.00: Perfect score on manifest cleanup / optimize_manifests version gate. Strong recovery theme continues — the version-gate pattern (Trino 470 for optimize_manifests) was applied correctly, all maintenance sequence claims verified, and the Spark fallback was given with exact syntax.
- Q2 4.00: STRUCT vs flat columns had strong framing and accurate trade-off analysis, but the schema-evolution DDL was wrong (`MODIFY COLUMN` instead of dotted-path `ADD COLUMN`). Resource/13 patched immediately.

### Resource fixes applied this iteration
- resources/13: Added explicit STRUCT schema evolution DDL callout — `ALTER TABLE ... ADD COLUMN metadata.new_field TYPE` (dotted path) is the correct form; `MODIFY COLUMN` is invalid for STRUCT.

### Suggested focus for Iter 326
- **Iceberg table maintenance** (4.580/23): probe manifest diagnostics angle — the judge noted the answer didn't surface `events$manifests` metadata table as a diagnostic. A question framed as "how do I know if I have a manifest problem before running the fix?" would test this.
- **Postgres-to-Iceberg ingestion** (4.490/115): probe STRUCT schema evolution directly — force the responder to give `ALTER TABLE ... ADD COLUMN parent.child TYPE` syntax. A question like "I need to add a new field to my existing STRUCT column — what DDL do I run?" would test whether the resource/13 fix held.
- **Multi-tenant analytics** (4.465/121 — weakest): still the lowest-scoring topic. Consider a different OPA angle — perhaps row-filter expression mechanics or the batched-uri scope limitation.
