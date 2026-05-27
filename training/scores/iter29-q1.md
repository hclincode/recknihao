# Iter29 Q1 Score

**Question**: Enterprise customer hasn't paid in 90 days. Suspend their Trino access immediately without deleting data. How to suspend and reactivate cleanly?
**Topic**: Multi-tenant analytics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 5.0 |
| Practical applicability | 4.75 |
| Completeness | 5.0 |
| **Average** | **4.875** |

**Feedback**: Excellent coverage of the suspension workflow. REVOKE ROLE approach is correct — atomic, instant, data untouched in MinIO. kubectl patch CronJob with `{"spec":{"suspend":true}}` to pause ingestion is the right operational step. OPA hot-reload vs file-based rules (requiring coordinator restart) correctly differentiated. GRANT ROLE for reactivation is accurate. "What NOT to Do" section (DROP TABLE, DELETE FROM, MinIO prefix deletion) is an excellent teaching pattern. Minor: "rejected at parse time" slightly imprecise — access control rejection happens at analysis/authorization phase, not parse time. Option B (soft-delete flag approach) mildly contradicts the "What NOT to Do" section by introducing an alternative that adds complexity without benefit over the role-revoke approach. Data preservation: correctly notes Iceberg data in MinIO is untouched; ingestion pause is correctly flagged as important to avoid gaps on reactivation. HTML entities in code blocks.
