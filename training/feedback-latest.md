# Judge Feedback — Iter 313

Date: 2026-05-27
Phase: extended
Topics: OPA columnMask for per-column PII redaction (Q1) + Cost model for analytical workloads at SaaS scale (Q2)

---

## Q1 — OPA columnMask for per-column PII redaction

### Score

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.0 | Config property `batch-column-masking-uri` is the correct name. Batch response format (`viewExpression` vs `expression`) is correctly identified. Hashing syntax `to_hex(sha256(to_utf8(email)))` is valid Trino. Material error: answer configures `batch-column-masking-uri` but writes Rego using `columnMask contains` — the batch endpoint expects rule named `batchColumnMasks`, not `columnMask`. This is a silent-failure trap (no masking applied, no error raised). |
| Beginner clarity | 4.5 | Clear framing ("you don't need to do it"), concrete before/after example of what user sees, no unexplained jargon, good "table stays singular" mental model. |
| Practical applicability | 4.5 | Drop-in `etc/access-control.properties` snippet matches on-prem Trino+OPA stack. Test plan with EXPLAIN guidance is actionable. Defers user-specific role rules to external governance doc (correct scope discipline per prod_info.md). |
| Completeness | 4.5 | Covers capability, config, Rego patterns, batch vs single endpoint, response-shape gotcha, testing, and table-duplication comparison. Composes with rowFilters correctly noted. Missing: Trino version note for column masking SPI; view-based fallback as alternative. |
| **Average** | **4.375** | **PASS** |

### What Worked
- "You don't need to do it" opens immediately with the right answer
- `batch-column-masking-uri` property name correct and reasoning (20 calls → 1) quantified
- Response-shape warning (`viewExpression` vs `expression`) is the exact footgun a beginner would hit
- `to_hex(sha256(to_utf8(email)))` verified as canonical Trino hashing chain
- EXPLAIN debugging tip points to the right place
- Composition with rowFilters explicitly noted — rows first, then column masks within surviving rows

### What Missed
- **CRITICAL: Rego rule name mismatch.** Answer configures batch endpoint but writes `columnMask contains {...}` Rego rule. Batch endpoint expects `batchColumnMasks` rule that iterates `input.action.filterResources` and emits `{"index": i, "viewExpression": {...}}`. Copying this Rego with the batch endpoint = silent failure, no masking.
- No `input.action.filterResources` iteration shown — required for batch Rego
- No Trino version note (column masking SPI added via PR #21997; batch column masking is even newer)
- No view-based alternative as fallback for cases where OPA column masking is unsupported or overkill

### Technical Accuracy
Verified: `batch-column-masking-uri` property name confirmed; batch response format `[{"index": i, "viewExpression": {...}}]` confirmed; `batchColumnMasks` is the correct Rego rule name for the batch endpoint (NOT `columnMask`); `to_hex(sha256(to_utf8(email)))` valid Trino binary function chain. Sources: trino.io/docs/current/security/opa-access-control.html, Trino PR #21997.

### Rubric Update
- Multi-tenant analytics: prior avg 4.470 across 112 questions → (4.470 × 112 + 4.375) / 113 = **4.469 across 113 questions**. Status: PASSED.

---

## Q2 — Cost model for analytical workloads at SaaS scale

### Score

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3.5 | BigQuery pricing cited as "~$2.50/TB (after cache hits)" — actual 2026 on-demand rate is $6.25/TB, making the $625-$1,250/month estimate roughly half of what it should be. Parquet 5-10x compression defensible for categorical event data at the upper end. Snowflake medium warehouse $300-$600/month plausible for intermittent (auto-suspended) workloads. Partition spec and FTE estimates are sound. |
| Beginner clarity | 5.0 | Zero assumed OLAP knowledge. Explains `expire_snapshots`, compaction, "per TB scanned" and "compute credits" in plain language. Three architectural decisions frame and rough cost table are excellent pedagogical structures. |
| Practical applicability | 5.0 | Perfectly tailored to on-prem Trino+Iceberg+MinIO+k8s stack from prod_info.md. Mentions Hive Metastore HA, MinIO storage amortization, k8s vCPU chargeback math, Spark ingestion executors. Engineer knows exactly which knobs to turn. |
| Completeness | 5.0 | Covers all four cost layers (storage, compute, engineering FTE), three architectural levers, rough cost table, and direct answer to "do architectural decisions reduce cost?" Missing: BigQuery free tier note; `bucket()` transform for future tenant growth; caveat that Snowflake $300-600/mo assumes auto-suspend. |
| **Average** | **4.625** | **PASS** |

### What Worked
- "Per-query marginal cost is zero, but costs hide elsewhere" is exactly the mental model OLTP-trained engineers need
- Engineering FTE positioned as dominant cost line — the single most important insight for managed vs self-hosted comparison, often missed
- Specific Iceberg maintenance operations named (`expire_snapshots`, `rewrite_data_files`) with weekly cadence
- "Streaming is the #1 way to create millions of tiny files" — concrete, memorable warning mapping to a real Iceberg failure mode
- Closing reframe: "architectural decisions don't make it cheap, they prevent it from becoming catastrophically expensive"
- `day(occurred_at), tenant_id` partition spec correct for 80 tenants

### What Missed
- **BigQuery pricing incorrect: $2.50/TB stated, actual $6.25/TB on-demand.** Makes the downstream $625-$1,250/month estimate roughly half of reality. Resources/16 fixed.
- Snowflake $300-$600/month is plausible only for auto-suspended workloads — caveat not stated
- No mention of BigQuery's free 1 TB/month tier or slots-based capacity pricing alternative
- `bucket()` transform for tenant_id not mentioned as a future-proofing note for growth beyond 80 tenants

### Technical Accuracy
- BigQuery: actual 2026 on-demand rate is ~$6.25/TB (not $2.50/TB). Source: cloud.google.com/bigquery/pricing
- Snowflake: 4 credits/hour × $2-4/credit; $300-600/mo plausible only if auto-suspended. Source: docs.snowflake.com
- Parquet Zstd compression: 5-10x defensible for event data with categorical columns + dictionary encoding. Source: community benchmarks
- Partition spec: `day(occurred_at), tenant_id` sound for 80 tenants. Source: Starburst Iceberg partitioning best practices

### Rubric Update
- Cost considerations: prior avg 4.500 across 3 questions → (4.500 × 3 + 4.625) / 4 = **4.531 across 4 questions**. Status: PASSED.

---

## Iter 313 Summary

**Iter 313 average: 4.50 — PASS** ✓

### Resource fixes applied (iter313 teacher pass)
- resources/05: explicit batchColumnMasks vs columnMask Rego rule name distinction; both endpoint patterns side-by-side with which Rego rule each requires; silent-failure trap warning
- resources/16: BigQuery pricing corrected from ~$2.50/TB to ~$6.25/TB on-demand; downstream cost calculations updated

### Suggested focus for Iter 314
- batchColumnMasks Rego rule correctly — follow-up to verify resource fix landed (answer must now show correct iteration over `input.action.filterResources`)
- Snowflake capacity (slots-based) pricing alternative vs on-demand — underrepresented angle on cost topic
- Iceberg bucket() transform for high-cardinality tenant partition (complement to day/tenant_id)
- Fresh angles on topics with the most room: OLAP vs OLTP mindset (4.542/3), storage sizing (4.500/3)
