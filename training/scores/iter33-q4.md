# Iter33 Q4 Score

**Question**: Two enterprise customers share the same Iceberg table: Customer A (healthcare, HIPAA, 90-day deletion) and Customer B (financial, SEC, 7-year retention). Both partitioned by `day(occurred_at)` and `tenant_id`. How to implement different retention policies per tenant without deleting other tenants' data?
**Topic**: Multi-tenant analytics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.50** |

**Feedback**: Excellent answer covering the full retention landscape. Correctly identified that partition DROP is unsafe on a shared table (day + tenant_id partitioning means one day-partition spans both tenants). Scheduled DELETE WHERE tenant_id + occurred_at approach is correct, followed by the proper 3-step reclamation sequence (rewrite_data_files + expire_snapshots). Correctly attributed storage release to expire_snapshots, not rewrite_data_files alone. Separate-tables-per-tenant correctly flagged as cleanest isolation. HIPAA audit log requirement and MinIO byte-verification mentioned. Minor gap: Iceberg table-level `write.data.retention.days` correctly noted as table-level-only (can't use for shared table), but partition-DROP warning could have been more prominent.
