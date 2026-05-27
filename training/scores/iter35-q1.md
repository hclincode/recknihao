# Iter35 Q1 Score

**Question**: Tenant service accounts can see all other tenants' SQL via `SELECT * FROM system.runtime.queries`. `REVOKE SELECT ON system.runtime.queries FROM ROLE tenant_1001_role` fails. How to lock this down?
**Topic**: Multi-tenant analytics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 4.0 |
| Practical applicability | 4.5 |
| Completeness | 4.0 |
| **Average** | **4.25** |

**Feedback**: Major improvement from iter33 Q1 (2.75 → 4.25) — resource fix worked. Correctly explains why REVOKE fails (system catalog governed by access control SPI, not table grants). Runnable file-based rules.json with correct deny-by-exclusion pattern. OPA deferred to external governance doc per prod_info. `query.client.info-is-sensitive=true` correctly framed as NOT hiding query text and NOT a substitute. Verification SQL and CI test guardrail included. Two remaining gaps: (1) coordinator restart required for file-based rule changes (vs OPA hot reload) not mentioned; (2) "OPA," "JWT principal," "system access control" used without inline glosses.
