# Iter141 Q1 — Judge Evaluation

**Question topic**: How to read Trino EXPLAIN ANALYZE output, identify bottleneck, and fix it. Specific scenario: query went from 8s → 45s after table grew 50GB → 200GB.

**Topics touched**:
- Query performance regression diagnosis: oncall workflow for slow queries
- Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup
- Iceberg partition design for SaaS: strategies, small-files, compaction

---

## Technical accuracy verification

Verified against trino.io/docs/current (Trino 481, near prod 467) and iceberg.apache.org/docs/latest:

| Claim | Verdict | Notes |
|---|---|---|
| `EXPLAIN ANALYZE` executes the query for real and collects timing | CORRECT | trino.io confirms: "executes the statement and shows the distributed execution plan with the cost of each operation" |
| Operator tree (Scan, Filter, Aggregate, Exchange) | CORRECT | Matches Trino concepts docs (tasks → pipelines → operators) |
| `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '128MB')` | CORRECT SYNTAX | Verified Trino Iceberg connector docs; default is 100MB; user can override |
| `$files` metadata table with `file_size_in_bytes` column | CORRECT | Verified in both Iceberg spec and Trino docs |
| `CALL iceberg.system.rewrite_data_files(table => ..., options => map(...))` | CORRECT | Spark named-argument syntax verified in iceberg.apache.org/docs/latest/spark-procedures/ |
| `target-file-size-bytes` and `min-input-files` options | CORRECT | Both are real options for BinPack strategy |
| `expire_snapshots(retention_threshold => '30d')` | CORRECT | 30d > 7d default floor `iceberg.expire-snapshots.min-retention`, so it will succeed |
| `remove_orphan_files(retention_threshold => '7d')` | CORRECT | 7d default floor; passes |
| 3-step sequence (rewrite → expire → orphan) | CORRECT | Order is right and each step has a distinct purpose |
| Splits = file assigned to worker task | MOSTLY CORRECT (oversimplified) | A split is actually a piece of work (often a file or a portion of a file for large files); the answer's framing is accurate enough for beginners |
| File-open overhead 10-50 ms per file | REASONABLE | Order-of-magnitude correct for S3/MinIO object opens; not officially specified but used commonly in guidance |

**Minor concerns**:
1. **CALL engine labeling missed.** `CALL iceberg.system.rewrite_data_files(...)` is presented under a Python `spark.sql(...)` block which makes the Spark-only context implicit — but the rubric's persistent pattern (multiple iterations have flagged this) prefers an explicit "Spark only — does NOT work in Trino" callout. The Trino alternative (`ALTER TABLE ... EXECUTE optimize`) is shown right after, so a careful reader can infer the split. Still a small gap given the long-running issue across iterations.
2. **`Files: 4860` in the sample TableScan line is illustrative**, not a real EXPLAIN ANALYZE output format — Trino actually reports under `Input:` and per-pipeline stats. The answer presents it as if Trino prints "Files: N" as a literal field. In real EXPLAIN ANALYZE you have to look at `Input rows`, `Input bytes`, `Physical input`, and the split summary from the coordinator. This is a minor inaccuracy in framing that could confuse a beginner who pastes their real EXPLAIN output and doesn't find a "Files:" line.
3. **CPU-time vs wall-time ratio** as I/O vs compute-bound heuristic is broadly correct but is more nuanced in Trino's per-operator output (the values are reported per operator and aggregated, not as a top-line "wall vs CPU"). Acceptable beginner heuristic.
4. **`avg_mb < 50` or `total_files > 1000`** as small-file thresholds are reasonable rules of thumb but not officially defined anywhere — fine for guidance.

---

## Dimension scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4 | All SQL syntax and procedure names verified correct. Two minor framings (literal "Files: N" in EXPLAIN output; CALL not explicitly engine-labeled despite recurring issue) keep this from 5. |
| Beginner clarity | 5 | Excellent table-driven walkthrough. Splits explained with concrete arithmetic ("3,000 × 20ms = 60s"). The "2x data should be 2x slow; 5x suggests file layout not volume" reasoning is exactly the mental model a SaaS engineer needs. Inline definitions for splits, operators, file-open overhead. |
| Practical applicability | 5 | Two diagnostic SQL queries the engineer can paste immediately. Compaction commands for both Spark (scheduled) and Trino (ad-hoc). Full 3-step maintenance sequence. Verification step after the fix. Nightly schedule template. Engineer can act today. |
| Completeness | 5 | Covers: how to read EXPLAIN ANALYZE, what to focus on (scan operator), the two common root causes, diagnostic SQL, the splits concept, the fix, the full maintenance sequence (not just compaction), verification, prevention. Hits the question from all angles without bloat. |

**Average**: (4 + 5 + 5 + 5) / 4 = **4.75 / 5** — PASS

---

## Strengths
- Two-cause framing (file count explosion vs partition pruning broken) gives the engineer a real decision tree.
- "8s → 45s on 4x data should be ~2x slower; the 5x gap points to file layout" is the kind of order-of-magnitude reasoning a senior would offer.
- Explicit reminder that `optimize` alone does not free MinIO storage — full sequence required.
- Verification step closes the loop.

## Weaknesses
- "Files: 4860" in the sample TableScan line is a stylized representation, not literal Trino output. A beginner pasting their real EXPLAIN ANALYZE might not find this field as written.
- CALL syntax inside a Python `spark.sql(...)` block makes the engine context implicit; explicit "Spark only — will fail in Trino" callout would close the recurring labeling gap flagged in prior iterations.
- 30d retention_threshold is fine but the answer could mention the 7d floor that the prod stack enforces, so engineers don't try `'1d'` and get a confusing failure.

## Recommendation
PASS. Strong answer covering the rubric topics with verified technical accuracy and excellent practical guidance. The two cosmetic issues (literal Files: field, implicit Spark labeling) are minor and do not block correctness.

---

## Rubric topics to update
- **Query performance regression diagnosis: oncall workflow for slow queries**: prior avg 5.0 over 2 questions; new running avg = (5.0 * 2 + 4.75) / 3 = **4.917** across 3 questions. PASSED.
- **Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup**: prior 4.602 over 14 questions; new = (4.602 * 14 + 4.75) / 15 = **4.612** across 15. PASSED.
- **Iceberg partition design for SaaS: strategies, small-files, compaction**: prior 4.589 over 15 questions; new = (4.589 * 15 + 4.75) / 16 = **4.599** across 16. PASSED.
