# Iter39 Q2 Score

**Question**: Healthcare customers need 90-day retention, standard customers 3 years. All share the same Iceberg events table. How to implement per-customer retention without creating a mess?
**Topic**: Multi-tenant analytics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 3 |
| **Average** | **3.75** |

**Feedback**: 3-step sequence (DELETE → rewrite_data_files → expire_snapshots) correctly engine-labeled and led with the right pitfall (only expire_snapshots physically removes bytes). Partition pruning explanation provided. Missing: (1) partition DROP not appropriate for shared table (day+tenant partition contains both tenants' data); (2) separate tables per tenant as cleanest approach for 12x retention spread; (3) `write.data.retention.days` is table-level only (not per-tenant); (4) partition order written as (tenant_id, day(event_ts)) but day-first is more efficient for range-pruning retention deletes.
