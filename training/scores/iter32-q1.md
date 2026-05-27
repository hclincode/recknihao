# Iter32 Q1 Score

**Question**: Security team worried about Trino query result caching causing cross-tenant data leaks. Is this a real risk and how to ensure caching is safe?
**Topic**: Multi-tenant analytics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.0 |
| Beginner clarity | 4.0 |
| Practical applicability | 3.0 |
| Completeness | 3.0 |
| **Average** | **3.50** |

**Feedback**: Correctly states Trino has no built-in persistent query result cache (verified: open feature request #20854). Existing defense-in-depth (JWT, OPA, scoped views, RBAC) correctly described. Answer buries confidence under excessive hedging ("I don't have detailed technical documentation"). Three key gaps: (1) doesn't explain that tenant-scoped views have different names = different query text = different cache key — the view architecture is exactly why caching is safe; (2) `system.runtime.queries` as a query-text snooping vector not mentioned — tenant roles should be denied system catalog access; (3) spooling section vague and doesn't name real cross-tenant spool risks. HTML entities.
