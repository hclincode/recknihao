# Judge Feedback — Iter 314

Date: 2026-05-27
Phase: extended
Topics: OLAP vs OLTP — do we actually need a separate analytics stack? (Q1) + OPA column masking silent failure — batchColumnMasks vs columnMask (Q2)

---

## Q1 — OLAP vs OLTP — do we actually need a separate analytics stack?

### Score

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | Row-vs-column storage characterization correct. Columnar 10–50x byte reduction realistic and supported. Tuning ladder (read replica, partial indexes, materialized views, partitioning, EXPLAIN ANALYZE) accurate and correctly ordered by risk/effort. Migration path (Spark JDBC → Parquet/MinIO → Iceberg/HMS → Trino) matches prod stack exactly. |
| Beginner clarity | 5.0 | Opens with "one row vs millions of rows" before any jargon. Concrete 30-column/2-needed worked example makes columnar advantage tangible. No unexplained acronyms. "The Real Distinction" closing reframes without restating. |
| Practical applicability | 5.0 | Direct decision tree: 5-step Postgres ladder first, then four concrete thresholds (50M rows, >2s after tuning, >3 users, multi-source joins), then 5-step migration recipe naming the engineer's actual stack components. Closing "next step" is unambiguous. |
| Completeness | 5.0 | Covers all four sub-questions asked: (1) is the distinction real, (2) what is fundamentally different, (3) can Postgres be tuned further, (4) when does tuning stop working. Adds migration path. Nothing material missing. |
| **Average** | **5.00** | **PASS** |

### What Worked
- "Row-at-a-time vs millions-at-once" nails the conceptual answer without storage-internals jargon
- 30-column/2-needed worked example makes the columnar advantage tangible — far better than abstract "I/O reduction"
- Tuning ladder ordered by risk/effort: read replica (zero risk) → partial index → matview → partitioning → EXPLAIN ANALYZE
- Concrete numeric thresholds (50M rows, >2s, >3 users) prevent the "it depends" non-answer
- Stack-aware migration path names MinIO, Iceberg, Hive Metastore, Trino, and Spark — not generic "use a data warehouse"
- Closes with one specific next action, not a generic recap

### What Missed (minor observations only)
- Could briefly note that matviews cost write amplification at refresh time and don't fix ad-hoc queries (answer covers this in spirit)
- "Spark writes Parquet to MinIO then register" slightly under-describes: in production, Spark with Iceberg writer commits Parquet + Iceberg metadata atomically in one step
- 10–50x byte reduction is realistic but conservative — for very wide tables can exceed 100x

### Technical Accuracy
All claims verified: row-vs-columnar storage characterization; PostgreSQL streaming replication for OLAP/OLTP separation; REFRESH MATERIALIZED VIEW syntax; Trino Iceberg connector projection pushdown and partition pruning. Stack matches prod_info.md exactly.

### Rubric Update
- OLAP vs OLTP: prior avg 4.542 across 3 questions → (4.542 × 3 + 5.00) / 4 = **4.657 across 4 questions**. Status: PASSED (improving).
- Also touched tangentially: "When to add OLAP" (tuning ladder + thresholds) and "OLTP-to-OLAP mindset" (design problem not config problem framing) — both benefit from this coverage.

---

## Q2 — OPA column masking silent failure — batchColumnMasks vs columnMask

### Score

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | `batchColumnMasks` rule name confirmed correct. Response shape `{"index": i, "viewExpression": {"expression": "..."}}` matches docs exactly. `input.action.filterResources[i].column.columnName` nested path correct per official Trino OPA docs. Silent failure behavior accurate. Four-row truth table correctly captures all combinations. |
| Beginner clarity | 4.5 | Opens with direct one-sentence diagnosis. "Two Different Places to Get Tripped Up" framing is highly accessible. Concrete email/hashing example tied to the user's scenario. Minor: doesn't explain what "Rego rule" means (acceptable — user is past that point). |
| Practical applicability | 5.0 | Corrected Rego is copy-paste ready. Single-column comparison Rego shows exactly what changes. CI test gives concrete query plus expected length/format assertions (64 chars, no @). Engineer can fix and verify immediately. |
| Completeness | 5.0 | Covers: rule name mismatch diagnosis, `batchColumnMasks` name, batch vs single-column endpoint comparison table, secondary response-shape trap (viewExpression vs expression), correct Rego example, single-column comparison, CI test, summary truth table. Nothing material missing. |
| **Average** | **4.875** | **PASS** |

### What Worked
- Direct diagnosis in first sentence: what's happening, why no error is raised
- Two-trap framing (wrong rule name + wrong response shape) preempts the follow-up failure the user would have hit next
- Side-by-side Rego makes structural differences visible at a glance
- Actionable CI test: length=64 and no-@ assertions are a real safety net
- Truth table: four rows covering all endpoint × rule name combinations
- **Confirmed that iter313's resource fix landed**: the responder correctly used `batchColumnMasks` this time (in iter313 Q1, the same responder made this exact bug)

### What Missed
- Could mention that OPA decision logs are the primary debugging tool to confirm whether the policy was evaluated and what it returned — a one-liner on enabling decision logging would help
- Could note that `batch-column-masking-uri` overrides `column-masking-uri` if both are set (footgun in mixed configurations)

### Technical Accuracy
All verified against trino.io/docs/current/security/opa-access-control.html:
- `batchColumnMasks` rule name: confirmed
- Response shape with `viewExpression`: confirmed
- `input.action.filterResources[i].column.columnName` path: confirmed
- Silent failure when rule not found: consistent with OPA+Trino integration

### Rubric Update
- Multi-tenant analytics: prior avg 4.469 across 113 questions → (4.469 × 113 + 4.875) / 114 = **4.473 across 114 questions**. Status: PASSED.

---

## Iter 314 Summary

**Iter 314 average: 4.94 — PASS** ✓ (best iteration this session)

### Notable
- Q1 perfect 5.00: OLAP vs OLTP answered completely — row-vs-column storage, tuning ladder, migration path all correct and stack-aware
- Q2 4.875: batchColumnMasks fix confirmed landed in resources — responder now gets it right after iter313 Q1 had the exact bug being diagnosed

### Suggested focus for Iter 315
- "Storage sizing and growth estimation for lakehouse workloads" (4.500/3 — only 3 questions, lowest question count among passing topics)
- "Real-time vs batch analytics trade-offs" (4.775/5 — underrepresented, fresh angles possible)
- "Schema design for analytics: denormalization, star schema basics" (4.60/5 — solid but ripe for an advanced angle)
- Continue probing OPA column masking angles (OPA decision log debugging; mixed endpoint config footgun)
