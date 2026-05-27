# Feedback — Iter 307 (Extended phase)

Date: 2026-05-27
Topics: approx_percentile for p99 latency dashboards (Q1) + Parquet column storage and JSON predicate pushdown (Q2)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | approx_percentile: T-Digest sketch, ARRAY multi-percentile, exact-vs-approx decision rule, PERCENTILE_CONT non-support in Trino | **4.75** | PASS |
| Q2 | Parquet min/max stats, three-level file skipping, JSON-as-string defeats skipping, two-tier schema promote solution | **4.85** | PASS |

**Iter 307 average: 4.80 — PASS** ✓

**Topic updates**:
- SQL query best practices for OLAP: 4.652/14 → **4.645/15 questions** (PASSED — stable)
- Column-oriented storage: 4.524/8 → **4.560/9 questions** (PASSED — improving)

---

## Resource fixes applied (PRIORITY — fixed before iter308)

### Resources 07 and 23: approx error figure corrected to 2.3%

The Q1 answer wrote "~2% relative standard deviation" when Trino's official aggregate-functions docs state **2.3% standard error**. This was also in the resources.

**Fixed in both resources 07 and 23:**
- "~2% error" → "2.3% standard error" for `approx_distinct` (HyperLogLog)
- "~2% std error" → "2.3% standard error" with correct ±2.3%/±4.6%/±6.9% breakdown
- Added `approx_percentile` accuracy note with 2.3% standard error and PERCENTILE_CONT non-support caveat
- Also added multi-percentile ARRAY syntax to resource 23

---

## What worked

### Q1 — approx_percentile (4.75)
1. Both ARRAY and per-column forms of approx_percentile shown with clear guidance on when to use each
2. Explicitly flags that Trino does NOT support `PERCENTILE_CONT WITHIN GROUP (ORDER BY ...)` — saves engineer a syntax error
3. Decision framework anchored on business consequence ("would 2% off harm the business?") — correct framing
4. Validate-against-existing-monitoring rollout pattern is the right production migration approach
5. Production dashboard query: valid Trino 467 syntax, uses partition pruning (`WHERE event_date = CURRENT_DATE`), groups by hour and endpoint, single pass
6. Edge case: small per-tenant samples (<1,000 rows) widen relative error — shows multi-tenant SaaS awareness

### Q2 — Parquet storage and JSON predicate pushdown (4.85)
1. Opens with a crisp one-line answer that directly addresses the question
2. Correctly explains per-row-group min/max statistics with a concrete row-group skipping example
3. Accurately covers dictionary encoding for low-cardinality columns with a clear example
4. Precisely diagnoses why JSON-as-string defeats file skipping: min/max captures byte range of whole JSON text, not contents
5. Cleanly enumerates three-level skipping cascade: manifest pruning → row-group pruning → column projection
6. Two-tier schema solution with concrete before/after DDL and Iceberg-native partitioning syntax
7. Correct Trino syntax: `json_extract_scalar(properties, '$.plan')` — verified
8. Correct PySpark syntax: `get_json_object("properties", "$.plan")` — verified
9. Decision rule for promote-vs-keep with cardinality guidance (10–10,000 sweet spot for dictionary encoding)
10. Production-stack-aware: MinIO I/O as bottleneck, Iceberg metadata-only `ADD COLUMN`, need to backfill old rows
11. Combined filter pattern: promoted columns prune files first, then `json_extract_scalar` runs on the reduced slice

---

## Minor gaps (not errors, not additional resource fixes needed)

### Q1
- "~2% error" stated (now fixed in resources) — should be 2.3% standard error per Trino docs
- "T-Digest algorithm" overcommits to a specific implementation name that Trino docs don't use for approx_percentile (safer: "quantile-sketch algorithm")
- Weighted variant `approx_percentile(x, w, percentages)` not mentioned
- Performance comparison table numbers not caveatted as "cluster-dependent, YMMV"

### Q2
- LIKE '%value%' (leading wildcard) defeating pruning even on typed string columns — not mentioned
- Parquet Page Index (sub-row-group skipping) not mentioned
- Sorting/clustering data by filter column to tighten min/max bounds not mentioned

---

## Suggested iter308 angles

1. **Postgres-to-Iceberg ingestion: JSONB column promotion at ingest time** — retest Q2's topic in a more practical angle: the engineer wants to know HOW to set up the ingest pipeline to promote JSON fields (dbt, Spark job, or dbt macro)
2. **Multi-tenant analytics: per-tenant query isolation with Trino views** — how to set up Trino views that bake in `WHERE tenant_id = ...` so tenants can never query each other's data
3. **Real-time vs batch trade-offs** — when is the freshness cost of batch acceptable, what are the operational triggers to move to streaming
4. **approx_percentile accuracy refinement** — retest the topic now that resources have 2.3% standard error corrected
