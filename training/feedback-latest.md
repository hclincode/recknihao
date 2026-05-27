# Judge Feedback — Iter 328

Date: 2026-05-27
Phase: extended
Topics: Multi-tenant analytics / OPA row-filter + column masking composition (Q1) + Iceberg table maintenance / $manifests correct column names (Q2)

---

## Q1 — OPA row-filter + column masking composition

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All five claims verified against official Trino OPA docs and PR #2891: (1) Row filter and column mask compose independently, both in same query plan. (2) OPA consulted only at planning, never during distributed execution. (3) `rowFilters` Rego rule name + `{"expression": "..."}` shape matches plugin contract. (4) `batchColumnMasks` (plural) correct for batch endpoint. (5) Coordinator restart required after adding any `opa.policy.*` URI property. |
| Beginner clarity | 5 | Directly addresses the engineer's specific worry (short-circuiting, narrow row filter bypassing mask). Before/after SQL pair makes "both apply in same plan" visually undeniable. |
| Practical applicability | 5 | Full config block, Rego for both rules, coordinator restart reminder, CI test suggestion. The silent-failure config trap reframes a realistic cause of perceived "interference" without inventing fake failure modes. |
| Completeness | 5 | Covers: composition guarantees, order, no short-circuit, why non-admin can't bypass mask via row filter, concrete example, configuration, Rego structure, restart requirement. |
| **Average** | **5.00** | **PASS** |

### What Worked
- Opens with the direct answer: "they do not interfere — they compose independently."
- Row filter → column mask order explained with a concrete SQL before/after that makes it visually obvious.
- The "non-admin cannot bypass mask" point addresses the engineer's exact worry directly.
- `batchColumnMasks` (plural) correctly distinguished from the URI path name `batchColumnMask` (singular) — a subtle gotcha correctly handled.
- Coordinator restart requirement is the most commonly forgotten practical step — proactively mentioned.

### What Missed
- Very minor: doesn't explicitly mention that both OPA calls happen in the same query analysis phase (they're two separate HTTP calls, not one combined call). This is the next natural question an engineer would have. Non-critical.

### Technical Accuracy (verified)
All five verification asks pass. No fabrications.

### Rubric Update
- Multi-tenant analytics: prior avg 4.473 across 123 questions → (4.473 × 123 + 5.00) / 124 = (550.179 + 5.00) / 124 = 555.179 / 124 = **4.477 across 124 questions**. Status: **PASSED** (continuing recovery).

---

## Q2 — $manifests correct column names

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All four claims verified against Trino Iceberg connector docs: (1) `length` is the correct column (not `manifest_length`). (2) `added_data_files_count` is real. (3) Full 12-column list matches Trino docs exactly. (4) `"events$manifests"` quoting syntax correct. |
| Beginner clarity | 5 | Leads with the exact wrong names the engineer guessed (`manifest_length`, `file_size`, `data_files_count`) and immediately corrects each one. Right-vs-wrong quoting examples side by side. Column reference table with plain-English descriptions. |
| Practical applicability | 5 | Copy-pasteable Trino 467 diagnostic query. Full column reference table. Before/after rewrite_manifests workflow with correct Spark CALL form (correctly flags `optimize_manifests` as Trino 470+ only). |
| Completeness | 5 | Answers both parts (file size column and files-per-manifest column), full column list, quoting syntax, diagnostic query, before/after verification. |
| **Average** | **5.00** | **PASS** |

### What Worked
- `length` (not `manifest_length`) stated immediately and emphatically.
- Three wrong guesses from the question (`manifest_length`, `file_size`, `data_files_count`) each explicitly corrected — no ambiguity.
- Full 12-column table with types and plain-English descriptions.
- Before/after rewrite_manifests workflow reinforces how to use the diagnostic.
- Correctly identifies `optimize_manifests` as Trino 470+ not available on Trino 467.

### What Missed
- None — perfect coverage for the question asked.

### Technical Accuracy (verified)
All four verification asks pass. Column names match Trino Iceberg connector docs exactly.

### Rubric Update
- Iceberg table maintenance: prior avg 4.556 across 24 questions → (4.556 × 24 + 5.00) / 25 = (109.344 + 5.00) / 25 = 114.344 / 25 = **4.574 across 25 questions**. Status: **PASSED** (recovering from iter327 manifest_length error).

---

## Iter 328 Summary

**Iter 328 average: (5.00 + 5.00) / 2 = 5.00 — PERFECT PASS** ✓ (Q1 PASS / Q2 PASS)

### Notable
- Q1 5.00: OPA row-filter + column masking composition — perfect score. The previous iteration's recommendation to probe this topic paid off. Resources/05 held correctly under direct probe of the composition guarantee.
- Q2 5.00: `$manifests` column names — the `length` fix from iter327 (resources/17) held perfectly. Responder correctly named `length` (not `manifest_length`), provided the full verified column list, and included correct before/after verification workflow.

### Resource fixes applied this iteration
None needed. Both resources held under direct probes.

### Suggested focus for Iter 329
- **Multi-tenant analytics** (4.477/124): consider probing OPA bundle management — how to structure and deploy OPA policy bundles (data.json naming requirement, bundle endpoint setup). This was identified as a potential gap in earlier sessions. Or probe HMS/Hive Metastore tuning for multi-tenant scenarios.
- **Postgres-to-Iceberg ingestion** (4.493/116 — has not been probed in a few iterations): probe the exactly-once deduplication pattern via LSN (the source_lsn field in the MERGE INTO pattern), or probe the `offset.flush.interval.ms` at-least-once delivery gap and how to absorb it.
- **Iceberg table maintenance** (4.574/25, recovering): consider probing `$snapshots` metadata table diagnostics (similar to the $manifests probe) — how to interpret snapshot history and identify which snapshots can be expired.
