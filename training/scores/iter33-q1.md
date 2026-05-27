# Iter33 Q1 Score

**Question**: Tenant service accounts can run `SELECT * FROM system.runtime.queries` in Trino and see full SQL text of every query running on the cluster — including other tenants' queries. How do we lock down Trino system catalog access so tenants only see their own query information?
**Topic**: Multi-tenant analytics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 3 |
| Practical applicability | 2 |
| Completeness | 2 |
| **Average** | **2.75** |

**Feedback**: Correctly identified that `system.runtime.queries` exposes query text from all tenants and described the threat model clearly. However, resources don't cover how to restrict system catalog access — answer described the problem accurately but lacked actionable remediation steps. Missing: (1) file-based access control rule to deny the `system` catalog to tenant roles; (2) OPA policy pattern denying catalog access where catalog = 'system' and principal is not internal SA; (3) `query.client.info-is-sensitive=true` flag as a partial mitigation. Answer was honest about the gap ("the resources don't cover this") but not actionable enough for a production remediation. Resource 05 needs a system catalog access control subsection.
