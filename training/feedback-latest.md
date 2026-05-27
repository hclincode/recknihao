# Judge Feedback — Iter 343

Date: 2026-05-27
Phase: extended
Topics: Postgres-to-Iceberg ingestion / MERGE_CARDINALITY_VIOLATION debugging (Q1) + Multi-tenant analytics / hardConcurrencyLimit queue-vs-reject behavior (Q2)

---

## Q1 — MERGE_CARDINALITY_VIOLATION Debugging (STRONG PASS — PERFECT)

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | Exact error string `MERGE_CARDINALITY_VIOLATION: Cannot perform Merge as multiple source rows matched a single target row` verified against Apache Iceberg source. row_number() OVER (PARTITION BY pk ORDER BY updated_at DESC) dedup recipe is canonical and verified. Root cause ranking (overlap-window re-reads first) correctly matches the engineer's scenario (just switched to incremental MERGE). LSN/Kafka-offset tiebreaker callout is correct and a non-obvious refinement. |
| Beginner clarity | 5.0 | "The error string to grep for" vs "NOT parse error" framing resolves confusion directly. "Why full refresh works but MERGE doesn't" paragraph directly addresses the engineer's stated question. Diagnostic table (same event_id, different updated_at → overlap window; same updated_at, different values → CDC duplicate) is actionable without OLAP background. |
| Practical applicability | 5.0 | Complete runnable code snippet with correct imports, window spec, row_number filter, createOrReplaceTempView, and MERGE SQL. Three-cause ranking with specific diagnostic guidance. Covers all common production scenarios for incremental sync. |
| Completeness | 5.0 | Covers: error definition, why full-refresh avoids it, three root causes ranked by likelihood, source-side dedup recipe with multiple tiebreaker options, diagnostic instructions. Resources/13 fix from iter342 confirmed holding. |
| **Average** | **5.00** | **STRONG PASS — PERFECT SCORE** |

### What Worked (everything)
- Exact runtime error name given correctly — "MERGE_CARDINALITY_VIOLATION," not "parse error."
- "Grep for MERGE_CARDINALITY_VIOLATION or 'multiple source rows matched', NOT for 'parse error'" guidance directly prevents the debugging dead-end flagged in iter342.
- Root cause 1 (overlap-window re-reads) is the correct most-likely cause for an engineer who "just switched from full refresh to incremental MERGE."
- Complete, runnable dedup recipe with imports.
- Diagnostic table maps observed data patterns to specific causes — engineers can debug without knowing theory.
- Resources/13 MERGE_CARDINALITY_VIOLATION fix from iter342 confirmed holding — second consecutive perfect score on this topic.

### What Missed (none — perfect score)
Minor non-deductions: no mention that dedup also applies when using MERGE for CDC streams (Debezium) where one row may have multiple events in a micro-batch. Not a gap for this specific question.

### Technical Accuracy Verification (verified by judge via WebSearch)
- MERGE_CARDINALITY_VIOLATION is the correct Iceberg runtime error — CONFIRMED per Apache Iceberg GitHub PR #2021 and Delta Lake issue #218
- row_number() OVER (PARTITION BY pk ORDER BY updated_at DESC) dedup recipe — CONFIRMED as canonical production pattern
- Full-refresh avoids the error because it doesn't use MERGE (no cardinality check) — CONFIRMED
- LSN/Kafka offset as tiebreaker for CDC sources — CONFIRMED as more reliable than updated_at for deterministic dedup

### Resource Fix Applied
None. Resources/13 fix (MERGE_CARDINALITY_VIOLATION error name, two cardinality directions, source-side dedup recipe) confirmed holding with second consecutive perfect score.

### Rubric Update
- Postgres-to-Iceberg ingestion: prior avg 4.497/124 → (4.497 × 124 + 5.00) / 125 = 562.628 / 125 = **4.501 across 125 questions**. Status: **PASSED** (recovering upward; two consecutive clean scores after MERGE_CARDINALITY_VIOLATION fix).

---

## Q2 — hardConcurrencyLimit Queue-vs-Reject Behavior (STRONG PASS)

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | Two-stage behavior (queue → QUERY_QUEUE_FULL reject) correct. maxQueued as queue depth cap correct. QUERY_QUEUE_FULL as error code correct. HTTP 200 for query-level errors correct. Minor error: resource-groups.json selector showed `"group": "global\\.free_tier"` (escaped dot) — `selectors[].group` uses literal string, not Java regex. Only `user` and `source` fields are regex. This could lead an engineer to write a selector that never matches. |
| Beginner clarity | 5.0 | The two-stage framing with explicit "Stage 1: Queued" vs "Stage 2: Queue full" labels directly answers the engineer's UI-copy question. The table showing HTTP status + error code + client behavior for each stage is exactly what someone writing UI error messages needs. "Your query is waiting" vs "your query failed" decision codified into concrete code branches. |
| Practical applicability | 5.0 | Complete resource-groups.json config with correct field values. Two-path client code (QUEUED vs QUERY_QUEUE_FULL). queued_time_ms monitoring tip for tuning maxQueued. HTTP 200 warning prevents a real production bug (engineer expecting 4xx for errors). |
| Completeness | 5.0 | Covers: two-stage behavior, both config fields, both error cases, concrete UI implementation, monitoring guidance. Nothing substantively missing for this question. |
| **Average** | **4.875** | **STRONG PASS** |

### What Worked
- Two-stage framing (Stage 1: queue, Stage 2: QUERY_QUEUE_FULL reject) directly answers the engineer's specific question: "do I say 'your query failed' or 'your query is waiting'?"
- HTTP 200 for query-level errors callout prevents a real production bug.
- Exact client-side code branches (`stats.state == "QUEUED"` vs `error.errorCode.name == "QUERY_QUEUE_FULL"`) are ready to paste into production.
- queued_time_ms monitoring guidance closes the loop on how to tune maxQueued.
- Pre-iter resources/05 hardConcurrencyLimit queue-vs-reject callout confirmed holding immediately.

### What Missed
1. **`selectors[].group` escaped dot** — `"group": "global\\.free_tier"` in the resource-groups.json example is wrong for selectors. `selectors[].group` is a literal string; only `user` and `source` fields are Java regex. A selector with escaped dot in the group field may fail to match queries, meaning the resource group never applies.

### Technical Accuracy Verification (verified by judge via WebSearch)
- hardConcurrencyLimit queues rather than rejects immediately — CONFIRMED per trino.io/docs/current/admin/resource-groups.html
- maxQueued caps the queue depth; exceeded → QUERY_QUEUE_FULL — CONFIRMED
- QUERY_QUEUE_FULL is correct error code — CONFIRMED
- HTTP 200 for query-level errors — CONFIRMED per Trino client REST API docs

### Resource Fix Applied
resources/05-multi-tenant-analytics.md: (1) Corrected `selectors[].group` dot-escape in resource-groups examples (literal string, not regex); (2) Added explicit contrast paragraph distinguishing resource-groups.json selectors (literal) from session-property-manager.json match-rules (Java regex) — both JSON keys are named `"group"` but with different matching semantics. This is a common confusion point.

### Rubric Update
- Multi-tenant analytics: prior avg 4.452/136 → (4.452 × 136 + 4.875) / 137 = 610.347 / 137 = **4.454 across 137 questions**. Status: **PASSED** (recovering upward; hardConcurrencyLimit queue-vs-reject correctly explained on first probe after resources/05 fix).

---

## Iter 343 Summary

**Iter 343 average: (5.00 + 4.875) / 2 = 4.9375 — STRONG PASS** ✓

### Notable
- Q1 5.00 PERFECT: MERGE_CARDINALITY_VIOLATION debugging nailed — second consecutive perfect score on Postgres-to-Iceberg after the iter342 resource fix. Error name, root causes, dedup recipe, and diagnostic guidance all correct.
- Q2 4.875 STRONG PASS: hardConcurrencyLimit two-stage behavior correctly explained on first probe after resources/05 fix. Minor selector JSON syntax error (`\\.` in group field) found and corrected in resources/05.
- Resources/05 now has a key architectural distinction documented: resource-groups.json selectors use literal string for `group`; session-property-manager.json match-rules use Java regex for `group`. This prevents future confusion between two JSON structures that look similar but have different semantics.

### Resource fixes applied this iteration
- **resources/05-multi-tenant-analytics.md**: selector group field literal-vs-regex distinction; contrast paragraph added.
- **resources/13-postgres-to-iceberg-ingestion.md** (iter342 fix): Confirmed holding with second consecutive perfect score.

### Suggested focus for Iter 344
- **Iceberg table maintenance** (4.575/33): Probe the complete weekly maintenance schedule ordering — compaction → expire_snapshots → remove_orphan_files → rewrite_manifests — and whether the responder can explain WHY that ordering matters (compaction before expire so new files get referenced before orphan scan; expire before orphan so expired snapshots don't protect orphaned files from deletion).
- **Multi-tenant analytics** (4.454/137): Probe the selector matching hierarchy — what happens when a query matches multiple resource group selectors? Does the first match win? Or most-specific?
- **Postgres-to-Iceberg** (4.501/125): Consider probing CDC with Debezium — specifically how to handle schema changes in the source Postgres table and what Iceberg schema evolution looks like.
