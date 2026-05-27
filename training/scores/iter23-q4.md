# Iter23 Q4 Score

**Question**: Compaction ran successfully last night but queries are still slow this morning. What went wrong and how do you fix it?
**Topic**: Iceberg table maintenance
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **5.0** |

**Feedback**: Perfect answer. Correctly identifies that compaction alone (rewrite_data_files) doesn't remove old files from MinIO — old snapshots still reference them and Trino still plans around all historical file metadata. The 4-step order (rewrite → expire → orphan → manifests) is correct and the explanation of WHY each step is needed is clear. "Compaction without expire_snapshots is like defragmenting a disk but keeping the old partition table" is an excellent analogy for beginners. EXPLAIN output interpretation (Files count pre vs post) is practical and actionable.
