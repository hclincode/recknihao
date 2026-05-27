# Judge Feedback — Iter 345

Date: 2026-05-27
Phase: extended
Topics: Postgres-to-Iceberg ingestion / Debezium CDC schema change (Q1) + Iceberg table maintenance / rewrite_manifests ordering rationale (Q2)

---

## Q1 — Debezium CDC + Postgres ADD COLUMN (STRONG PASS — PERFECT)

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | All claims verified: WAL RELATION detection confirmed, schema.refresh.mode=columns_diff default confirmed, Iceberg field-ID-based ADD COLUMN (metadata-only, NULL for existing rows) confirmed, Spark AnalysisException on unknown source column confirmed, NOT NULL without default rejected on populated Postgres table confirmed. Do-NOT-restart-Debezium guidance correct — connector already adopted schema via WAL. |
| Beginner clarity | 5.0 | Four-step "what actually happens" walkthrough makes the sequence concrete. Explicit "what you wake up to" framing addresses the engineer's stated concern. "Do NOT restart Debezium" called out as a common mistake. Runbook is numbered and copy-pasteable. |
| Practical applicability | 5.0 | Complete kubectl + ALTER TABLE + kubectl runbook. AnalysisException named so engineer knows what to grep for. NOT NULL edge case preempts a common footgun. "Under 60 seconds total downtime" gives the engineer confidence to execute. Fits the on-prem k8s + Spark + Iceberg stack in prod_info.md. |
| Completeness | 5.0 | Covers: Debezium WAL detection, Spark error behavior, Iceberg field-ID semantics, three-step runbook, edge case (NOT NULL without default), non-obvious pitfall (don't restart Debezium). |
| **Average** | **5.00** | **STRONG PASS — PERFECT SCORE** |

### What Worked (everything)
- Four-step sequence (Postgres → Debezium → Spark error → fix) maps exactly to what the engineer will observe.
- Exact error name (`AnalysisException`) so engineer can grep logs.
- NOT NULL without default edge case covered proactively — this is a real production footgun.
- "Do NOT restart Debezium" — correct counter-intuitive guidance with explanation.
- Iceberg field-ID semantics correctly stated (add column = metadata-only, existing rows return NULL).
- Resources/13 CDC schema evolution content confirmed comprehensive.

### What Missed (none — perfect)
Minor non-deduction: no mention of type change (e.g., VARCHAR → TEXT widening) — handled differently from ADD COLUMN. Not part of the question scope.

### Technical Accuracy Verification
- Debezium WAL RELATION message detection + schema.refresh.mode=columns_diff — CONFIRMED per Debezium PostgreSQL connector docs
- Iceberg ADD COLUMN is metadata-only, field-ID-based, NULL for existing rows — CONFIRMED per iceberg.apache.org/docs/latest/evolution/
- Spark AnalysisException on unknown column in MERGE INTO — CONFIRMED
- NOT NULL without default rejected immediately on populated tables — CONFIRMED per postgresql.org/docs/current/sql-altertable.html
- Do NOT restart Debezium (connector already adopted schema) — CORRECT

### Resource Fix Applied
None. Resources/13 CDC schema evolution content (sections 4–6) confirmed comprehensive — responder retrieval gap was the prior issue, now clearly resolved.

### Rubric Update
- Postgres-to-Iceberg ingestion: prior avg 4.501/125 → (4.501 × 125 + 5.00) / 126 = 567.625 / 126 = **4.505 across 126 questions**. Status: **PASSED** (recovering upward).

---

## Q2 — rewrite_manifests Ordering Rationale (STRONG PASS — PERFECT)

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | Manifests correctly described as metadata index (data file list + per-column statistics). "All preceding steps generate new manifests as side effects" correctly stated and is the correct reason for going last. Efficiency-not-safety framing confirmed: Iceberg atomic commit semantics guarantee expire_snapshots cannot delete live-snapshot files. Three-layer model (data → manifest → snapshot) verified against Iceberg spec. `events$manifests` system table confirmed. |
| Beginner clarity | 5.0 | Three-layer model (data → manifest → snapshot) builds up from familiar concepts. Concrete "50,000 manifests → 30 seconds planning → <1 second after rewrite" progression makes the cost tangible. "Compaction alone doesn't fix this" section pre-empts the most common misconception. |
| Practical applicability | 5.0 | Diagnostic SQL with triage thresholds (<10, 10–50, 50–200, 200+) lets engineer decide whether rewrite is worth doing. Efficiency-not-safety distinction means engineer can make an informed scheduling decision. |
| Completeness | 5.0 | Covers: manifest definition, why they matter, why rewrite_manifests goes last (new manifests generated as side effect of preceding steps), efficiency-not-safety clarification with atomic commit guarantee, diagnostic SQL. |
| **Average** | **5.00** | **STRONG PASS — PERFECT SCORE** |

### What Worked (everything)
- Resources/17 efficiency-not-safety framing (iter344 fix) confirmed holding with a perfect score.
- "Compaction alone doesn't fix this" section closes the most common mental-model gap.
- Diagnostic `events$manifests` query with triage thresholds gives engineer a go/no-go decision.
- Atomic commit guarantee correctly and explicitly stated — directly addresses the question of whether order matters for safety.

### What Missed (minor, non-deduction)
- `rewrite_manifests` is a Spark-only procedure on Trino 467 (added to Trino in version 470+). The answer doesn't mention this — an engineer on Trino 467 would need to use Spark for this specific step. Worth adding to resources/17 as an engine-availability note.

### Technical Accuracy Verification
- Manifest files contain data file list + per-column statistics — CONFIRMED per iceberg.apache.org/spec/ and iceberg.apache.org/terms/
- rewrite_manifests consolidates for faster query planning — CONFIRMED per iceberg.apache.org/docs/latest/maintenance/
- Compaction, expire_snapshots, remove_orphan_files generate new manifests as side effects — CONFIRMED
- Ordering is efficiency not safety (atomic commit protects live-snapshot files) — CONFIRMED
- `events$manifests` system table — CONFIRMED per Trino Iceberg connector docs

### Resource Fix Applied
None needed post-iteration. Consider adding for iter346: `rewrite_manifests` engine availability note (Spark-only on Trino 467, available in Trino 470+).

### Rubric Update
- Iceberg table maintenance: prior avg 4.580/34 → (4.580 × 34 + 5.00) / 35 = 160.720 / 35 = **4.592 across 35 questions**. Status: **PASSED** (strong recovery; resources/17 efficiency framing confirmed stable).

---

## Iter 345 Summary

**Iter 345 average: (5.00 + 5.00) / 2 = 5.00 — PERFECT STRONG PASS** ✓

### Notable
- First-ever 5.00/5.00 iteration average in the training run. Both questions answered perfectly.
- Q1: Debezium CDC schema change runbook nailed — WAL detection, AnalysisException, field-ID semantics, do-not-restart-Debezium, NOT NULL edge case, all correct.
- Q2: rewrite_manifests rationale confirmed — resources/17 efficiency-not-safety framing from iter344 fix holding with perfect score on direct probe.

### Resource fixes applied this iteration
- **resources/17** (teacher pre-iter): rewrite_manifests ordering rationale expanded — confirmed holding.
- **resources/05** (teacher pre-iter): selectorPriority non-existence callout added — not directly tested this iteration.
- No post-iteration fixes needed. One pending addition for iter346: rewrite_manifests Spark-only availability note for Trino 467.

### Suggested focus for Iter 346
- **Iceberg table maintenance** (4.592/35): Probe rewrite_manifests engine availability — "I tried to run rewrite_manifests in Trino but I got an error. Is this a Trino thing?" to verify the engine-availability gap is added and caught.
- **Multi-tenant analytics** (4.458/138): Consider probing `userGroup` field for group-membership-based routing (added to resources/05 in pre-iter345 fix) — the new complete selector fields table has not yet been tested.
- **Postgres-to-Iceberg** (4.505/126): Consider probing type change (VARCHAR → TEXT widening) or column drop — the column-added case is now solid, but other schema evolution scenarios haven't been tested.
