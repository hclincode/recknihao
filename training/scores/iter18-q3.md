# Score: Iteration 18, Question 3

**Date**: 2026-05-24
**Phase**: Final
**Question**: We just signed 10 new enterprise customers. What's the checklist to properly onboard a new tenant into a multi-tenant analytics platform?
**Rubric topics**: Multi-tenant analytics: isolating customer data in SaaS

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.25 | Three-phase structure (isolation model, data ingestion, query-layer isolation) is correct. Partition spec (tenant_id, day(event_ts)) is correct. overwritePartitions() for idempotency — correct. GRANT + GRANT ROLE + REVOKE ALL three-step sequence — correct and complete. GDPR 3-step sequence (DELETE → rewrite_data_files → expire_snapshots) — correct. HTTP event listener configuration — correct. OPA deferred to external governance doc — correct per prod_info.md. Bug: CALL statements use `spark_catalog.system.*` — the production stack configures the Spark catalog as `iceberg` (based on Spark configs shown elsewhere as `spark.sql.catalog.iceberg=...`), so the correct syntax is `CALL iceberg.system.rewrite_data_files(...)`, not `CALL spark_catalog.system.rewrite_data_files(...)`. |
| Beginner clarity | 5.0 | Exceptional. Phase structure, copy-paste-ready checklist, verification tests, table of service account roles — all make this immediately actionable. "Why both GRANT and REVOKE?" callout is exactly the right content to prevent the silent-no-op bug. |
| Practical applicability | 4.75 | Correctly covers the full lifecycle: table creation, ingestion, view layer, role layer, large export pattern, GDPR offboarding, audit logging. Production stack (Trino 467, Iceberg 1.5.2, MinIO, OPA, JWT, Kubernetes) referenced throughout. |
| Completeness | 4.75 | Five-phase coverage including optional audit logging. The checklist summary is excellent. Gaps: (1) no mention of testing the partition spec before loading 10 new tenants; (2) spark_catalog catalog name error (see accuracy). |
| **Average** | **4.69** | |

---

## What the answer got right

1. Partition spec (tenant_id, day(event_ts)) — correct for 10–50 tenant scale.
2. GRANT ROLE ... TO USER (both parts required) — correctly flagged as mandatory.
3. REVOKE ALL on base table — correctly identified as the security-critical step.
4. GDPR 3-step (DELETE → rewrite_data_files → expire_snapshots) — complete and correct.
5. OPA deferred to external governance document — correct per prod_info.md.
6. CALL labeled as "Spark procedures" — engine labeling partially correct.
7. HTTP event listener (`context.user`, `metadata.query`, `ioMetadata.inputs`) — correctly described with nested JSON field paths.

## What the answer got wrong

1. **`spark_catalog` catalog name.** The CALL statements use `CALL spark_catalog.system.rewrite_data_files(...)`. But the production Spark catalog is configured as `iceberg` (via `spark.sql.catalog.iceberg=org.apache.iceberg.spark.SparkCatalog`). The correct syntax is `CALL iceberg.system.rewrite_data_files(...)`. This error would cause a runtime failure.

## Resource fix needed

`resources/13-postgres-to-iceberg-ingestion.md` CALL statement examples may use inconsistent catalog names. Standardize to `iceberg.system.*` throughout, matching the Spark config (`spark.sql.catalog.iceberg=...`).

## Topic score updates

**Multi-tenant analytics**
- Prior: avg 4.010 across 14 questions
- This answer: 4.69 (15th angle — tenant onboarding checklist)
- New running avg: (56.14 + 4.69) / 15 = **4.055** across 15 questions
- Status: PASSED (stable above 4.0)
