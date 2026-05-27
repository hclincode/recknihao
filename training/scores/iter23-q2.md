# Iter23 Q2 Score

**Question**: Enterprise customer BigCorp needs dedicated analytics pipeline: data isolation, query isolation, 7-year retention. How do you set this up?
**Topic**: Multi-tenant analytics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.94** |

**Feedback**: Strong answer. Model 1 (separate namespace `iceberg.bigcorp`) selection rationale is well-argued. Kubernetes ServiceAccounts for query vs ingestion roles are correctly separated. Trino resource groups with `"user": "bigcorp-analytics"` matching JWT principal (not role name) is correct. 7-year retention via `expire_snapshots` with `older_than => current_timestamp - INTERVAL '2555' DAY` is correct. Isolation limits clearly stated (MinIO I/O and K8s worker nodes are shared). Minor: CALL statements in the maintenance schedule section are not consistently labeled as Spark SQL only — a reader could attempt to run `CALL iceberg.system.expire_snapshots()` in Trino, which fails silently.
