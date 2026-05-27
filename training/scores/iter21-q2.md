# Iter21 Q2 Score

**Question**: 200 tenants, one enterprise "Acme" generates 10x more events. Weekly cross-tenant report times out at 12 min; small tenants finish in 30s. EXPLAIN shows normal Files but Wall>>CPU.
**Topic**: Query performance regression diagnosis (new topic, 2nd angle)
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **5.0** |

**Feedback**: Outstanding. Root cause correctly identified as compounding small-files + partition skew. Wall>>CPU correctly explained as file-opening overhead (10-50ms per file) rather than computation. `$files` metadata query for diagnosis is accurate. CALL statement explicitly labeled "Submit via spark-submit or a Spark job pod, NOT Trino" — exactly the engine label that was missing in iter20 Q2. Both fixes (dedicated Acme table, bucket sub-partition) are correct. Production constraints (no concurrent ingestion+compaction) noted. `iceberg.system.*` catalog name used correctly throughout.
