# Judge Feedback — Iter 326

Date: 2026-05-27
Phase: extended
Topics: STRUCT schema evolution — adding a field with dotted-path ADD COLUMN (Q1) + OPA batched-uri scope vs row-filter latency (Q2)

---

## Q1 — Adding a new field to an existing STRUCT column in Iceberg

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All four critical claims verified: (1) `ALTER TABLE ... ADD COLUMN metadata.sso_enabled BOOLEAN` (dotted-path) correct per Iceberg Spark DDL docs. (2) Metadata-only with NULL for old rows — correct per Iceberg field-ID resolution spec. (3) `col("metadata").withField("sso_enabled", value)` — valid PySpark 3.1.0+. (4) `ALTER COLUMN metadata ADD sso_enabled` correctly flagged as invalid. Trino 467 supports the dotted-path form (added in Trino 422). |
| Beginner clarity | 4.5 | Strong scaffolding: opens with the exact correct DDL immediately, explains why the wrong syntax fails, field-ID mechanism explained in plain English ("Iceberg matches by numeric field ID, not column name"). Comparison table between top-level and STRUCT syntax is scannable. Minor: field-ID mechanism explanation could be slightly more beginner-accessible. |
| Practical applicability | 5 | Engineer has everything needed: immediate DDL to run, Spark ingestion code updated to include the new field, backfill option with `withField` + `coalesce`, backfill gotcha called out (silent NULL exclusion from dashboards), and a four-step rollout timeline. Production-stack fit strong (Trino 467, Spark, MinIO, Iceberg 1.5.2). |
| Completeness | 5 | Covers all asked questions: correct syntax, why wrong syntax fails, NULL behavior for old rows, ingestion job changes, drop/rename parity. Also anticipates the follow-on question about schema stability contract vs MAP/VARCHAR alternatives. |
| **Average** | **4.875** | **PASS** |

### What Worked
- Opens with correct DDL immediately — no preamble.
- Why `ALTER COLUMN ... ADD` fails is explained without jargon ("Iceberg does not support an `ALTER COLUMN ... ADD` form").
- Field-ID mechanism in plain English makes the NULL-for-old-rows behavior intuitive rather than magic.
- Backfill `withField` + `coalesce` pattern with the "silent NULL exclusion" gotcha is a real production trap — calling it out proactively is the right move.
- Four-step rollout timeline gives the engineer a concrete action sequence.
- Drop/rename parity (same dotted-path syntax) extends the mental model without extra explanation.

### What Missed
- Minor: the comparison table between top-level and STRUCT syntax is clean but could add DROP and RENAME rows for completeness (drop/rename are mentioned in prose but not in the table).
- Minor: no mention of what happens when you DROP and re-ADD a STRUCT field — re-ADD gets a NEW field ID, so old data for the original field is not accessible via the new column. This is an advanced gotcha but relevant for teams that rename fields by drop-then-add rather than RENAME COLUMN.

### Technical Accuracy (verified)
1. Dotted-path `ADD COLUMN metadata.sso_enabled BOOLEAN` — CORRECT per Iceberg Spark DDL docs
2. Metadata-only with NULL for old rows — CORRECT per Iceberg field-ID resolution spec
3. `withField` PySpark syntax — VALID (Spark 3.1.0+)
4. `ALTER COLUMN metadata ADD` invalid — CORRECT; dotted-path ADD COLUMN is the only form

### Rubric Update
- Postgres-to-Iceberg ingestion: prior avg 4.490 across 115 questions → (4.490 × 115 + 4.875) / 116 = (516.35 + 4.875) / 116 = 521.225 / 116 = **4.493 across 116 questions**. Status: **PASSED** (recovering from MODIFY COLUMN error in iter325).

---

## Q2 — OPA batched-uri scope vs row-filter latency

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All five claims verified against official Trino OPA docs: (1) `batched-uri` applies only to FilterTables/Schemas/Columns/Catalogs/Views — confirmed. (2) No `cache-ttl-seconds` / no decision cache — confirmed. (3) Row-filter evaluation uses separate `opa.policy.row-filters-uri` endpoint — confirmed. (4) Sidecar deployment for low-latency OPA calls — industry-standard, accurate. (5) Endpoint mapping table matches official 10-property config list. Critically avoids the fabricated `opa.policy.cache-ttl-seconds` property that caused iter322 failure. |
| Beginner clarity | 5 | Schema visibility vs row visibility distinction explained in plain English ("which resources can you see?" vs "which rows can you see?"). Batching analogy (50 tables → 50 calls vs 1 call) makes the performance difference concrete. Debug logging guidance is actionable. |
| Practical applicability | 5 | Four concrete levers for reducing row-filter latency with config snippets and expected impact (10-20ms savings from sidecar). Diagnostic logging procedure to confirm what's actually slow. Complete recommended config block at the end is copy-pasteable. |
| Completeness | 5 | Covers all parts of the question: why batched-uri didn't help, what it does batch, what row-filter evaluation actually is, and what does actually reduce overhead. Endpoint mapping table consolidates the full picture. |
| **Average** | **5.00** | **PASS** |

### What Worked
- Opens directly with the answer: "batched-uri does NOT apply to row-filter expression evaluation."
- Schema-visibility-vs-row-visibility framing is the core mental model engineers need — stated clearly early.
- Batching example (50 tables → 50 calls vs 1 call) makes the benefit of batched-uri concrete, so the engineer understands what it IS good for.
- "Cannot be batched — each query is independent" explains WHY row filters can't be batched, not just that they can't.
- Correctly avoids the fabricated `opa.policy.cache-ttl-seconds` property.
- Sidecar deployment as the highest-impact latency lever (10-20ms savings) is the right recommendation.
- Debug logging guidance lets engineer confirm the diagnosis before making infrastructure changes.
- Endpoint mapping table is a clean reference for the full OPA plugin config surface.

### What Missed
- Very minor: the answer doesn't explicitly call out the `opa.policy.column-masking-uri` vs `opa.policy.batch-column-masking-uri` distinction in the body text (only in the table) — but both appear in the table and the question is about row-filter latency, so this is acceptable.

### Technical Accuracy (verified)
All five verification asks pass. No fabrications.

### Rubric Update
- Multi-tenant analytics: prior avg 4.465 across 121 questions → (4.465 × 121 + 5.00) / 122 = (540.265 + 5.00) / 122 = 545.265 / 122 = **4.469 across 122 questions**. Status: **PASSED** (continuing recovery from iter322 fabrication drop).

---

## Iter 326 Summary

**Iter 326 average: (4.875 + 5.00) / 2 = 4.9375 — PASS** ✓ (Q1 PASS / Q2 PASS)

### Notable
- Q1 4.875: STRUCT schema evolution DDL — the resource/13 fix from iter325 held perfectly. Responder correctly gave `ADD COLUMN metadata.sso_enabled BOOLEAN` (dotted-path) as the fix, explained why `ALTER COLUMN ... ADD` fails, and correctly described NULL behavior for old rows. Field-ID mechanism explained in plain English.
- Q2 5.00: Perfect score on batched-uri scope / row-filter mechanics. Responder correctly explained schema visibility (batchable) vs row visibility (per-query HTTP call, not batchable), avoided the fabricated cache-ttl property, and gave four concrete latency-reduction levers.

### Resource fixes applied this iteration
None needed. Both resources held under direct probes.

### Suggested focus for Iter 327
- **Multi-tenant analytics** (4.469/122): continue probing OPA angle — per the rubric, this topic is the lowest scored at 4.469. Consider probing column masking (`opa.policy.column-masking-uri` vs `opa.policy.batch-column-masking-uri`) or the OPA bundle management / data structure requirements. Both are documented in resources/05 and haven't been probed recently.
- **Iceberg table maintenance** (4.580/23): probe a different angle — the manifest diagnostics angle the Q1 judge suggested (how do I know if I have a manifest problem before running the fix? Using `events$manifests` metadata table). Or probe `rollback_to_snapshot` as a safety net.
- **Postgres-to-Iceberg ingestion** (4.493/116): recovering. Consider a question about the LAG_BUFFER / replica lag watermark pattern, or the exactly-once semantics deduplication via LSN, to probe a different part of the resource.
