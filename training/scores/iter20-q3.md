# Iter20 Q3 Score

**Question**: Coworker says Trino can run maintenance with ALTER TABLE ... EXECUTE — when should you use Spark CALL vs Trino ALTER TABLE?
**Topic**: Iceberg table maintenance
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4.5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.875** |

**Feedback**: Excellent comparison answer. Correct Trino ALTER TABLE EXECUTE syntax for optimize, expire_snapshots, remove_orphan_files. Correctly states rollback is Spark-only. Uses `iceberg.system.*` catalog correctly in all CALL statements. Decision matrix table is clear and directly useful. Operation ordering (compaction → expire_snapshots → remove_orphan_files → rewrite_manifests) and conflict avoidance (don't run ingestion and compaction on same partition simultaneously) are both covered correctly. Minor dock on clarity: K8s CronJob YAML example is practical but may be dense for a beginner with no Kubernetes background.
