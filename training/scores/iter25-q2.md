# Iter25 Q2 Score

**Question**: Enterprise customer terminating. Must export all data within 7 days and GDPR-delete within 30 days. Complete offboarding procedure for 3 Iceberg tables.
**Topic**: Multi-tenant analytics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.94** |

**Feedback**: Outstanding answer. Two-phase structure (export then delete) is correct with explicit instruction not to delete before customer confirms receipt. INSERT INTO ... SELECT correctly labeled as a Trino operation (not Spark) — iter17 fix holding. GDPR 3-step deletion sequence (DELETE → rewrite_data_files → expire_snapshots) correct with `older_than => current_timestamp() - INTERVAL '0' DAY, retain_last => 1` for full historical erasure. CALL statements labeled Spark-only consistently. `iceberg.system.*` catalog name correct throughout. Rollback safety section (reversible before expire_snapshots, permanent after) is an excellent operational safeguard. Summary table with Engine column is the clearest engine-labeling device in the training run. Common mistakes section prevents the most dangerous failure mode (signing off after DELETE only). Minor: HTML entity encoding in code blocks.
