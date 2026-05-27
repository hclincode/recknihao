# Iter25 Q4 Score

**Question**: Compaction (rewrite_data_files) ran at 2 AM but 3 remaining steps didn't. Storage GREW by 18 GB instead of shrinking. Why? What to do?
**Topic**: Iceberg table maintenance
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 4.75 |
| **Average** | **4.75** |

**Feedback**: Correctly explains why storage grew: rewrite_data_files creates new large files without deleting old ones; old files are still referenced by previous snapshots until expire_snapshots runs; remove_orphan_files then physically deletes unreferenced files from MinIO. The 18 GB growth is temporary and expected. Remediation (run the remaining 3 steps in order) is correct with Spark-only labeling. The `older_than => current_timestamp - interval '30' day, retain_last => 10` example is practical for normal use. The ordering explanation ("expire_snapshots before remove_orphan_files, not the other way") is correct. "Maintenance is the price of safety" closing reinforces the key lesson. Minor: engine label sentence structure is garbled ("The `Spark SQL only — does not run in Trino.` CALL statements are Spark SQL only") — awkward but unambiguous; HTML entities in code blocks.
