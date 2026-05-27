# Judge Feedback — Iter 327

Date: 2026-05-27
Phase: extended
Topics: Multi-tenant analytics / OPA column masking (Q1) + Iceberg table maintenance / manifest diagnostics with $manifests metadata table (Q2)

---

## Q1 — OPA column masking in Trino

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All five claims verified: (1) `column-masking-uri` vs `batch-column-masking-uri` config keys correct verbatim. (2) Rule names `columnMask` (singular) and `batchColumnMasks` (plural) confirmed against official Trino OPA docs. (3) Batch response shape with nested `viewExpression` wrapper confirmed exactly. (4) One-call-per-column vs one-call-per-table semantics confirmed (GitHub issue #21359 is the motivation for the batch endpoint). (5) All SQL masking expressions use valid Trino built-ins. |
| Beginner clarity | 5 | Opens with direct answer ("yes, Trino and OPA support column-level masking"). "OPA doesn't mask data in the database — it tells Trino to rewrite the column" is the clearest possible framing for a beginner. Two-pattern structure (single vs batch) is well-labeled with when to use each. |
| Practical applicability | 5 | Engineer has everything: config properties, Rego rule structure for both patterns, real SQL masking expressions for their specific use cases (credit card first-4-digits, email hash), the silent-failure trap with a CI test pattern, and explicit tie-back to their existing Trino 467 + OPA row-filter setup. |
| Completeness | 5 | Covers both halves of the question: yes it's possible, and Trino does the rewrite while OPA returns the expression. Silent-failure trap is proactively covered. Performance implications (per-column vs per-table call count) explained. |
| **Average** | **5.00** | **PASS** |

### What Worked
- Config key names exactly match the official Trino OPA docs.
- Rego rule names `columnMask` (singular) and `batchColumnMasks` (plural) — the singular/plural distinction is a non-obvious gotcha that the answer catches correctly.
- Nested `viewExpression` → `expression` structure for batch response is the most common implementation trap; calling it out with the "what happens if you get it wrong" note is excellent.
- Silent-failure trap with a concrete CI test pattern is responsible engineering guidance.
- SQL masking expressions (CONCAT/SUBSTR for credit cards, sha256 for email) are exactly what the engineer asked for.

### What Missed
- Very minor: doesn't mention that column masking and row filtering compose — if a user has BOTH a row filter AND a column mask applied, both fire independently (row filter reduces rows, column mask rewrites the value). Engineers sometimes wonder if they interfere. Non-critical omission since the question didn't ask.

### Technical Accuracy (verified)
All five verification asks pass. No fabrications.

### Rubric Update
- Multi-tenant analytics: prior avg 4.469 across 122 questions → (4.469 × 122 + 5.00) / 123 = (545.218 + 5.00) / 123 = 550.218 / 123 = **4.473 across 123 questions**. Status: **PASSED** (continuing recovery).

---

## Q2 — Iceberg manifest diagnostics with `$manifests` metadata table

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3 | Most claims correct — `$manifests` metadata table exists, Trino syntax is correct, column names mostly right, threshold guidance reasonable, `rewrite_manifests` Spark-only on Trino 467 correct. One consequential error: `manifest_length` is NOT a real column. The actual column is `length`. Three separate code blocks use `SUM(manifest_length)` — all fail at runtime with "Column not found." |
| Beginner clarity | 5 | Excellent framing — explains what manifest bloat is and why it causes planning latency before diving into diagnostics. Threshold table (< 10 healthy, 200+ too many) is immediately usable. Before/after verification pattern is clean. |
| Practical applicability | 3 | Strong on the diagnostic approach and sequence, but the richer diagnostic SQL fails at runtime due to the `manifest_length` column name error. The baseline `SELECT COUNT(*) FROM "events$manifests"` works, but the more useful multi-column query would return a "Column not found" error on production. |
| Completeness | 5 | Covers: what manifest bloat is, how to query `$manifests`, threshold guidance, column meanings, relationship to small file count, when to run vs skip, before/after verification, complete diagnostic runbook. |
| **Average** | **4.00** | **PASS** |

### What Worked
- `$manifests` metadata table as the diagnostic tool — this is exactly what was missing from prior answers.
- Trino quoted-name syntax `"events$manifests"` is correct.
- Baseline `SELECT COUNT(*) FROM "events$manifests"` works and is the right starting query.
- Threshold guidance (< 10, 10-50, 50-200, 200+) is practical and aligned with community benchmarks.
- `rewrite_manifests` correctly identified as Spark-only on Trino 467.
- Before/after count comparison is the right verification pattern.

### What Missed
- **Column name error**: `manifest_length` does NOT exist. The real column is `length`. All three `SUM(manifest_length)` queries fail at runtime. This is the single most consequential error.
- Column list accuracy: some column names are correct (`partition_spec_id`, `added_data_files_count`, `existing_data_files_count`, `deleted_data_files_count`) but `manifest_length` is fabricated.

### Resource Fix Applied
resources/17 updated: added `$manifests` diagnostics section after the `rewrite_manifests` procedure block with:
- Verified column names (especially `length`, NOT `manifest_length`)
- Complete column reference table with descriptions
- Explicit CRITICAL callout: "the column is `length`, NOT `manifest_length`"
- Before/after query templates using the correct column names

### Technical Accuracy (verified)
The Trino Iceberg connector docs list `$manifests` columns: `content`, `path`, `length`, `partition_spec_id`, `added_snapshot_id`, `added_data_files_count`, `added_rows_count`, `existing_data_files_count`, `existing_rows_count`, `deleted_data_files_count`, `deleted_rows_count`, `partition_summaries`. The column is `length`, not `manifest_length`.

### Rubric Update
- Iceberg table maintenance: prior avg 4.580 across 23 questions → (4.580 × 23 + 4.00) / 24 = (105.34 + 4.00) / 24 = 109.34 / 24 = **4.556 across 24 questions**. Status: **PASSED**.

---

## Iter 327 Summary

**Iter 327 average: (5.00 + 4.00) / 2 = 4.50 — PASS** ✓ (Q1 PASS / Q2 PASS)

### Notable
- Q1 5.00: OPA column masking — perfect score. All config keys, Rego rule names, response shapes, and SQL expressions verified exactly. The singular/plural `columnMask`/`batchColumnMasks` distinction correctly handled.
- Q2 4.00: `$manifests` diagnostic approach was correct (right table, right Trino syntax, right threshold guidance, right Spark fix) but one fabricated column name (`manifest_length` → should be `length`) causes all richer diagnostic queries to fail at runtime. Resource/17 patched immediately.

### Resource fixes applied this iteration
- resources/17: Added `$manifests` diagnostics section with verified column list. Critical callout: column is `length`, NOT `manifest_length`. Includes threshold guidance, before/after templates, and complete column reference table.

### Suggested focus for Iter 328
- **Iceberg table maintenance** (4.556/24): probe `$manifests` diagnostics again to verify the `length` column fix held — ask a question specifically about which columns to use in `$manifests` to measure manifest health.
- **Multi-tenant analytics** (4.473/123): probe the composition of row filters + column masking — the Q1 judge noted the answer didn't cover this. A question like "I have both row-level security and column masking set up — do they interact or conflict?" would test this.
- **Postgres-to-Iceberg ingestion** (4.493/116): consider probing a different angle — LAG_BUFFER replica lag watermark or exactly-once deduplication via LSN, to probe a different part of resource 13.
