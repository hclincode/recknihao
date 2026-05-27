# Judge Feedback — Iter 342

Date: 2026-05-27
Phase: extended
Topics: Multi-tenant analytics / softMemoryLimit admission control vs mid-flight kill (Q1) + Postgres-to-Iceberg ingestion / MERGE INTO ON clause primary key requirement (Q2)

---

## Q1 — softMemoryLimit Admission Control vs kill_query Mid-Flight Kill (STRONG PASS — PERFECT)

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | All claims verified against trino.io: softMemoryLimit is admission control only (confirmed per resource-groups.html — once admitted, running queries are not killed or suspended by softMemoryLimit changes). CALL system.runtime.kill_query(query_id => '...') syntax confirmed in system connector docs. query.max-memory in config.properties IS the per-query hard ceiling that kills queries mid-flight when distributed memory exceeds the limit (confirmed per properties-resource-management.html). |
| Beginner clarity | 5.0 | "Bouncer at the door, not a power cord" analogy is immediately comprehensible. Direct "No." in sentence one. "Right now" vs "After the incident" action plan perfectly calibrated to an engineer in incident mode. |
| Practical applicability | 5.0 | Engineer has everything needed for immediate action: find query ID in Trino UI, run CALL system.runtime.kill_query with exact syntax, follow up with two-layer config fix. Three-layer defense (softMemoryLimit + query.max-memory + query.max-memory-per-node) provides a complete architectural recommendation. |
| Completeness | 5.0 | Covers: the direct "no" to the engineer's question, WHY softMemoryLimit doesn't kill running queries, the correct immediate-relief tool (kill_query), the two-layer defense architecture, sequenced next steps. All four dimensions of the question addressed. |
| **Average** | **5.00** | **STRONG PASS — PERFECT SCORE** |

### What Worked (everything)
- "Bouncer at the door, not a power cord" — one of the clearest mechanical analogies in the training run.
- Direct "No." in sentence one, followed by the corrective action in the same sentence. No hedging.
- Comparison table with explicit "Kills in-flight query? NO / YES" column resolves the confusion that has persisted across iterations.
- "Right now" → "After the incident" action sequencing perfectly matches incident-response mental mode.
- Pre-iter resources/05 admission-control callout confirmed holding with a perfect score — best validation of a resource fix this training run.

### What Missed (minor non-deductions)
- kill_query `message =>` optional parameter not shown (useful for logging why a query was killed)
- Coordinator restart required for query.max-memory changes not mentioned
- OPA grant required for killing another user's query not mentioned

### Technical Accuracy Verification (verified by judge via WebSearch)
- softMemoryLimit is admission control only (does not kill in-flight) — CONFIRMED per trino.io/docs/current/admin/resource-groups.html
- CALL system.runtime.kill_query(query_id => '...') signature — CONFIRMED per trino.io/docs/current/connector/system.html
- query.max-memory is the per-query hard ceiling that kills mid-flight — CONFIRMED per trino.io/docs/current/admin/properties-resource-management.html

### Resource Fix Applied
Teacher pre-iter applied resources/05 admission-control vs mid-flight kill CRITICAL callout. Confirmed holding with perfect 5.00 score.

### Rubric Update
- Multi-tenant analytics: prior avg 4.448/135 → (4.448 × 135 + 5.00) / 136 = 605.48 / 136 = **4.452 across 136 questions**. Status: **PASSED** (recovering strongly upward; admission-control distinction now perfectly explained).

---

## Q2 — MERGE INTO ON Clause Primary Key Requirement (PASS)

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3.5 | Core thesis correct (ON clause must uniquely identify target rows). But two factual errors: (1) "parse error" is wrong — Iceberg's cardinality check fires at runtime; the error is `MERGE_CARDINALITY_VIOLATION` / "Cannot perform Merge as multiple source rows matched a single target row." (2) "cross-join blowup" is not how Iceberg behaves — it detects the multi-match condition and fails with a runtime error, not a cartesian explosion. Also, two cardinality directions conflated: many-source-to-one-target → runtime error; one-source-to-many-target → silent corruption (no error). |
| Beginner clarity | 4.5 | The failure table mapping each wrong column to why it fails is excellent — directly answers the engineer's "what if I use updated_at or tenant_id" question. The one-rule closing is memorable and sharp. Minor deduction for "cross-join blowup" which is technically incorrect and could confuse. |
| Practical applicability | 4.5 | Composite PK syntax shown, idempotency tie-back is useful, the rule for choosing ON clause columns is actionable. Missing: source-side dedup recipe for the common case where overlap-window reads produce duplicate PKs in the source delta (triggering MERGE_CARDINALITY_VIOLATION even with a correct ON clause). |
| Completeness | 4.0 | Covers: uniqueness requirement, three failure modes (two with accuracy issues), composite PK syntax, idempotency. Missing: source-side dedup recipe; MERGE_CARDINALITY_VIOLATION error string (so engineers can grep for it); the two cardinality directions (direction 1 = runtime error, direction 2 = silent corruption with no error). |
| **Average** | **4.125** | **PASS** |

### What Worked
- Core thesis stated clearly: ON clause must uniquely identify rows.
- Failure table with `updated_at` / `tenant_id` / `created_at` / `id` rows directly addresses the engineer's specific question.
- Composite PK syntax shown: `ON t.tenant_id = s.tenant_id AND t.event_id = s.event_id`.
- Idempotency property correctly tied back to incremental sync re-read safety.
- "The one rule" closing is memorable.

### What Missed
1. **"Parse error" is wrong** — cardinality violation fires at runtime, not parse time. Engineers grepping logs for "parse error" won't find the actual `MERGE_CARDINALITY_VIOLATION` message.
2. **"Cross-join blowup" is not what happens** — Iceberg detects the multi-match and fails at runtime; it doesn't produce a cartesian product.
3. **Two cardinality directions not distinguished**: (a) many source rows matching one target row → runtime `MERGE_CARDINALITY_VIOLATION`; (b) one source row matching many target rows → silent update of ALL matching target rows, no error — the dangerous one because it silently corrupts data.
4. **Source-side dedup recipe missing** — overlap-window incremental reads (which the lag-buffer intentionally creates) commonly produce duplicate source PKs. Even with a correct ON clause, duplicate source PKs trigger `MERGE_CARDINALITY_VIOLATION`. The fix is `row_number() OVER (PARTITION BY pk ORDER BY updated_at DESC)` to keep only the latest version of each source PK before the MERGE.

### Technical Accuracy Verification (verified by judge via WebSearch)
- MERGE_CARDINALITY_VIOLATION is the correct runtime error for multi-match — CONFIRMED per Iceberg docs and community sources
- Iceberg detects multi-match and fails; does not produce a cartesian product — CONFIRMED
- One-source-to-many-target silently updates all matched rows — CONFIRMED
- row_number() dedup pattern on source delta is the standard fix for duplicate source PKs — CONFIRMED

### Resource Fix Applied
resources/13-postgres-to-iceberg-ingestion.md: (1) Replaced "parse error" with MERGE_CARDINALITY_VIOLATION runtime error name; (2) Distinguished two cardinality directions with explicit failure modes; (3) Added source-side dedup recipe using row_number() OVER (PARTITION BY pk ORDER BY updated_at DESC) for overlap-window duplicate PKs.

### Rubric Update
- Postgres-to-Iceberg ingestion: prior avg 4.500/123 → (4.500 × 123 + 4.125) / 124 = 557.625 / 124 = **4.497 across 124 questions**. Status: **PASSED** (minor drop; resource fix applied; MERGE_CARDINALITY_VIOLATION error name and two cardinality directions now documented).

---

## Iter 342 Summary

**Iter 342 average: (5.00 + 4.125) / 2 = 4.5625 — STRONG PASS** ✓

### Notable
- Q1 5.00 PERFECT: softMemoryLimit as admission control vs query.max-memory as mid-flight killer perfectly explained. The pre-iter resources/05 CRITICAL callout confirmed holding with a perfect score — best resource-fix validation in the training run.
- Q2 4.125 PASS: MERGE INTO ON clause core correctly explained but "parse error" label wrong (it's MERGE_CARDINALITY_VIOLATION at runtime) and the two cardinality directions conflated. Resource fix applied to resources/13.

### Resource fixes applied this iteration
- **resources/13-postgres-to-iceberg-ingestion.md**: MERGE_CARDINALITY_VIOLATION error name, two cardinality directions, source-side dedup recipe with row_number().
- **resources/05-multi-tenant-analytics.md** (teacher pre-iter fix): admission-control vs mid-flight kill CRITICAL callout — confirmed holding with perfect 5.00.

### Suggested focus for Iter 343
- **Postgres-to-Iceberg ingestion** (4.497/124): Probe the MERGE_CARDINALITY_VIOLATION error specifically — "I got this error, what does it mean and how do I fix it?" — to verify the resource fix held and responder can now explain source-side dedup.
- **Multi-tenant analytics** (4.452/136): Probe something not yet tested — e.g., resource group `hardConcurrencyLimit` queuing behavior under high load (what happens when a free-tier customer hits the concurrency ceiling — does their query error or wait?).
- **Iceberg table maintenance** (4.575/33): Consider probing the complete weekly maintenance schedule (what runs in what order and why) to verify the canonical ordering is now stable.
