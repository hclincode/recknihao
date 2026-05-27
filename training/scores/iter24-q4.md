# Iter24 Q4 Score

**Question**: How to know if Iceberg table needs urgent compaction vs can defer? What health metrics to check and what thresholds trigger "do it now"?
**Topic**: Iceberg table maintenance
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 5 |
| Practical applicability | 4.75 |
| Completeness | 4.75 |
| **Average** | **4.81** |

**Feedback**: Excellent diagnostic framework. TL;DR decision table first is the right pedagogical choice. $snapshots.total_data_files_count as primary health metric is correct and practical. EXPLAIN ANALYZE Files count as the real-world impact test is the correct recommendation. Wall time >> CPU time interpretation (file-open overhead, not computation) is accurate. CALL iceberg.system.rewrite_data_files() correctly labeled "Spark SQL only — does not work in Trino" consistently throughout. CALL iceberg.system.expire_snapshots() also correctly labeled. `iceberg.system.*` catalog name correct. "Compaction without expire_snapshots is only half the fix" section correctly reinforces the 4-step order from prior training. Minor issues: (1) PERCENTILE() function in Query 2 does not exist in Trino — correct function is `approx_percentile(col, fraction)` as a GROUP BY aggregate; (2) HTML entity encoding (`&lt;`/`&gt;`) in code blocks and tables; (3) `$files` table query is complex and may have column name differences across Iceberg versions.
