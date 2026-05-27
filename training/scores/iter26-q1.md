# Iter26 Q1 Score

**Question**: Running Postgres and Iceberg in parallel — three enterprise tenants want Iceberg analytics but we're not ready for full cutover. Route specific tenants to Iceberg without changing frontend code.
**Topic**: Multi-tenant analytics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.5 |
| Practical applicability | 4.5 |
| Completeness | 4.75 |
| **Average** | **4.625** |

**Feedback**: Correctly identifies the routing layer pattern — per-tenant config table read in the backend application layer, query gateway routes to Postgres or Trino+Iceberg based on config. Per-tenant Trino views + GRANT/REVOKE for isolation post-cutover. Rollback plan (revert a tenant back to Postgres) is present. CALL statements labeled Spark-only. Beginner clarity and practical applicability docked one point each: the critical operational concern (ingestion must run for all tenants even if only 3 query Iceberg, keeping both systems in sync) is underemphasized; the schema drift problem (what if a column changes in Postgres but isn't yet reflected in the Spark job?) is not addressed. HTML entities in code blocks (persistent artifact).
