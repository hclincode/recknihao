# Iter22 Q2 Score

**Question**: GDPR right to erasure — physically delete all tenant data from Iceberg tables so bytes are gone from MinIO, not just hidden.
**Topic**: Multi-tenant analytics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **5.0** |

**Feedback**: Perfect answer. "Why the Obvious Approach Fails" section (MVCC + delete files) is the clearest explanation of Iceberg's immutable file model in the entire training run. Correct 3-step sequence: DELETE → rewrite_data_files → expire_snapshots. GDPR-specific parameters (`older_than => '0' day, retain_last => 1`) distinguished from routine maintenance defaults — critical distinction. `iceberg.system.*` catalog correct throughout. DELETE labeled as Trino or Spark (correct); CALL labeled as Spark-only (correct). Summary table with compliance status per step (Not compliant → Not compliant → GDPR-compliant) is brilliant pedagogical tool. Recovery window and final checklist complete the answer.
