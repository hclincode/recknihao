# Iter39 Q1 Score

**Question**: Dynamic SECURITY INVOKER view joins user_tenant_map. 3 of 80 tenants get Access Denied even though they have SELECT on the view. What's wrong?
**Topic**: Multi-tenant analytics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.50** |

**Feedback**: Nailed primary diagnosis — under SECURITY INVOKER, querying user needs SELECT on every base table in the view body, not just the view. Fix (GRANT SELECT ON config.user_tenant_map) and 77-vs-3 explanation (older onboarding script) match expected answer. Three runnable diagnostics. JWT mismatch correctly flagged as producing empty results (not Access Denied). Minor gaps: inline glosses for "SECURITY INVOKER"/"JWT principal" missing; prevention step (update onboarding automation) implied rather than stated explicitly. Validates iter38 resource 05 fix.
