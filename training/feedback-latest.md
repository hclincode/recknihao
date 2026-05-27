# Judge Feedback — Iter 318

Date: 2026-05-27
Phase: extended
Topics: Schema evolution mid-CDC — ADD COLUMN in Postgres (Q1) + OPA row-filter performance under high concurrency (Q2)

---

## Q1 — Schema evolution mid-CDC: ADD COLUMN in Postgres

### Score

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.25 | Core mechanics correct: Debezium picks up new columns via RELATION messages on next DML; Iceberg ADD COLUMN is metadata-only; historical rows return NULL. Two inaccuracies: (1) `UPDATE SET *` / `INSERT *` wildcards do NOT trigger schema evolution in MERGE — they expand to the target table's current columns at plan time. MERGE INTO does not support auto schema evolution in Iceberg 1.5.2. (2) Backfill snippet uses `mergeSchema=true` without the required `write.spark.accept-any-schema=true` table property. |
| Beginner clarity | 4.5 | Clear structure: "what Debezium did right" → "why Iceberg is behind" → "fix sequence" → "root cause". Two-outcome framing (silent drop vs AnalysisException) helps self-diagnosis. WAL/checkpoint terms used but explained in context. |
| Practical applicability | 4.75 | Engineer knows what to do: pause Spark, ALTER Iceberg, resume. Explicit 30-60s downtime estimate. Concrete SQL. Backfill recipe. "Don't restart Debezium" warning prevents a likely wrong reaction. Fits on-prem Spark+Iceberg+HMS stack. |
| Completeness | 4.5 | Covers detection, root cause, fix, prevention, historical backfill. Missing: `write.spark.accept-any-schema` table property; MERGE INTO auto schema evolution not supported in Iceberg 1.5.2; DROP COLUMN / TYPE CHANGE asymmetry; schema-drift monitoring. |
| **Average** | **4.50** | **PASS** |

### What Worked
- Correctly identifies the failure is on the Iceberg consumer side, not Debezium
- Pause-ALTER-resume is the right operational pattern for on-prem Iceberg
- Two-outcome framing (silent NULL drop vs AnalysisException) is practically useful
- Backfill caveat ("historical rows will be NULL") correctly surfaced
- "Don't restart Debezium" prevents a common wrong reflex

### What Missed
- **MERGE wildcards don't trigger schema evolution** — `UPDATE SET *` / `INSERT *` expand to target's current columns at plan time. The ALTER step is mandatory; wildcards just make post-ALTER behavior less brittle (now added to resources/13)
- **`write.spark.accept-any-schema=true` required** for `mergeSchema=true` in backfill to add missing columns — backfill snippet was incomplete (now added to resources/13)
- ADD vs DROP vs TYPE CHANGE asymmetry not mentioned (DROP is destructive in Iceberg; TYPE CHANGE only allows widening promotions)
- Schema-drift monitoring not mentioned

### Technical Accuracy (verified)
Debezium ADD COLUMN behavior confirmed. Iceberg MERGE INTO schema evolution limitation confirmed (apache/iceberg#5548). `write.spark.accept-any-schema` requirement confirmed per iceberg.apache.org/docs/latest/spark-writes/.

### Rubric Update
- Postgres-to-Iceberg ingestion: prior avg 4.490 across 109 questions → (4.490 × 109 + 4.50) / 110 = **4.494 across 110 questions**. Status: PASSED.

---

## Q2 — OPA row-filter performance under high concurrency

### Score

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.75 | All verifiable claims match Trino 467+ OPA plugin docs. OPA called once per query at analysis time (not per row) — correct. `batched-uri` endpoint for FilterTables/FilterSchemas bundling — correct. `batch-column-masking-uri` overrides `column-masking-uri` — exact docs quote. `io.trino.plugin.opa.OpaHttpClient` debug logger — exact. `metrics.timer_rego_query_eval_ns` field — exact. "1 OPA pod per ~20 concurrent users" rule of thumb not in official docs but labeled as rule of thumb. Minor: example OPA URL path is a convention, not a Trino constant. |
| Beginner clarity | 4.5 | Explains once-per-query vs per-row distinction up front. Concrete numbers (200 tables = 200 calls without batching, 50 users × 30 columns = 1,500 calls). Doesn't define "Rego" or "OPA bundle" but question implies engineer already runs OPA. |
| Practical applicability | 5.0 | Diagnose-first ordering (enable debug log → count calls → tune). Concrete config snippets. Tuning levers ordered by impact. K8s replica example matches prod environment. Coordinator restart reminder. Engineer can act immediately. |
| Completeness | 4.75 | Covers: call frequency, where extra calls come from, diagnosis path, batched-uri, batch column masking + precedence, horizontal OPA scaling, Rego optimization. Missing: `opa.http-client.*` connection pool tuning (max-connections, request-timeout); OPA bundle polling impact; information_schema query amplification (Trino Issue #22323). |
| **Average** | **4.75** | **PASS** |

### What Worked
- Direct answer to both parts of the user's question (call frequency + what to tune)
- Correctly framed row filter as 1 call per query and identified real cost driver as SHOW TABLES / column masking fan-out
- Diagnose-before-tune ordering with exact logger name
- Coordinator restart reminder (reinforcing iter317 fix)
- Honest framing of rule of thumb

### What Missed
- `opa.http-client.*` connection pool properties not mentioned — when scaling OPA replicas, Trino's HTTP client also needs tuning (now added to resources/05)
- Diagnostic decision tree (call count vs per-call latency) not made explicit — user asked "is it OPA or Trino config?" (decision tree added to resources/05)
- Information_schema query amplification (Issue #22323) not mentioned

### Technical Accuracy (verified)
All verifiable claims confirmed against Trino 481 OPA docs and OPA decision-logs docs. `batch-column-masking-uri` precedence quote exact. `io.trino.plugin.opa.OpaHttpClient` logger name exact.

### Rubric Update
- Multi-tenant analytics: prior avg 4.478 across 116 questions → (4.478 × 116 + 4.75) / 117 = **4.480 across 117 questions**. Status: PASSED.

---

## Iter 318 Summary

**Iter 318 average: 4.625 — PASS** ✓

### Notable
- Q1 4.50: Schema evolution answer correct on core mechanics; MERGE wildcard/schema-evolution misconception and missing `write.spark.accept-any-schema` caught; fixed in resources/13
- Q2 4.75: OPA performance answer comprehensive; HTTP client tuning and diagnostic decision tree gaps fixed in resources/05

### Resource fixes applied this iteration
1. **resources/13-postgres-to-iceberg-ingestion.md** — "MERGE INTO and schema evolution: wildcards are not enough" section; `write.spark.accept-any-schema=true` + `mergeSchema=true` requirement; ADD vs DROP vs TYPE CHANGE asymmetry note
2. **resources/05-multi-tenant-analytics.md** — OPA HTTP client tuning properties (`opa.http-client.*`); diagnostic decision tree (call count vs per-call latency)

### Suggested focus for Iter 319
- "Postgres-to-Iceberg ingestion" (4.494/110 — probe DROP COLUMN behavior or TYPE CHANGE widening; or schema-drift monitoring pattern)
- "Multi-tenant analytics" (4.480/117 — probe OPA bundle management: how Rego policies are distributed, bundle polling, bundle signing)
- "Storage sizing" (4.521/6 — probe time-travel cost: how many snapshots to keep, what expire_snapshots does to storage)
- "OLAP vs OLTP" (4.657/4 — probe a harder angle: hybrid HTAP, when Trino federation over Postgres is sufficient vs full migration)
