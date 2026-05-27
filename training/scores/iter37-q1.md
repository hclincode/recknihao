# Iter37 Q1 Score

**Question**: Dynamic view with `WHERE tenant_id = current_user` — every tenant sees the same rows (view creator's data). What went wrong and how to fix it?
**Topic**: Multi-tenant analytics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.25** |

**Feedback**: Resource fix working — correctly produces SECURITY INVOKER solution, two-account test recipe, base-table REVOKE, blast-radius tradeoff, 200+ tenant inflection. Technical accuracy gap: explanation that `current_user` "resolves to the view creator" under SECURITY DEFINER contradicts Trino docs — `current_user` always returns the query executor regardless of security mode. The actual DEFINER-vs-INVOKER difference is whose table grants are used. Fix still works but mechanism explanation is incorrect. Missing: `WITH (security_invoker = true)` alternative syntax; grant requirement on user_tenant_map lookup table for INVOKER views (engineers will hit confusing access-denied on the lookup table).
