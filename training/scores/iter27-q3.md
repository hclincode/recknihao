# Iter27 Q3 Score

**Question**: Acme Corp (tenant_id=1001) acquired by GlobalTech (tenant_id=2002). GlobalTech wants 3 years of combined historical analytics. How to merge two tenants' Iceberg data without losing rows? What are the risks?
**Topic**: Multi-tenant analytics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.875** |

**Feedback**: Most operationally comprehensive answer in the iteration. Three approaches with explicit trade-offs: Trino view (immediate, zero risk, zero downtime), CTAS (physical merge, clean at rest), UPDATE row-level (safest when data overlaps). `overwritePartitions()` correctly preferred over `createOrReplace()` and `append()` for the physical write. CALL syntax uses `iceberg.system.*` (correct). `expire_snapshots` uses `current_timestamp - interval '30' day` (correct Trino syntax). Row count verification with concrete expected output (before/after numbers must match) is the most important safety check and is correctly presented as non-negotiable. GDPR snapshot concern (old snapshots still exist until expire_snapshots, auditor can time-travel back) is a subtle and important point. Access control cleanup (revoke Acme role after 2-week verification window) is practical. Ingestion pause recommendation prevents CommitFailedException. Recommended sequence (view immediately + physical merge in weekend window) is the right two-step approach. Beginner clarity docked slightly: "partition column rewrite confusion" section uses "cosmetic" framing that may undersell the importance of running compaction. HTML entities in code blocks.
