# Iter35 Q2 Score

**Question**: 80 tenants, each with a hardcoded per-tenant Trino view (`WHERE tenant_id = 'acme'`). Is there a dynamic view using the logged-in user so we don't provision a new view per tenant?
**Topic**: Multi-tenant analytics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 3 |
| **Average** | **3.75** |

**Feedback**: Core pattern correct — `current_user` + user_tenant_map JOIN + REVOKE on base table. Correctly enforces that both GRANT (view) and REVOKE (base table) are required. Missing key points: (1) Trino views default to SECURITY DEFINER, so `current_user` in the view body returns the view owner — must specify `SECURITY INVOKER` for this to work; (2) security tradeoff: one bug in user_tenant_map breaks isolation for ALL tenants simultaneously vs per-tenant views where a bug affects only one; (3) caching benefit of per-tenant views (distinct SQL = distinct cache key); (4) 80 tenants is below the ~200+ inflection where dynamic view becomes compelling over per-tenant views.
