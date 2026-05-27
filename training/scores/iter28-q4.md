# Iter28 Q4 Score

**Question**: Enterprise customer wants sub-tenant isolation: 8 business units each see only their own events within tenant_id=5001. How to implement without creating 640 views?
**Topic**: Multi-tenant analytics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.5 |
| Completeness | 4.75 |
| **Average** | **4.625** |

**Feedback**: Scalability analysis (8×80=640 views unmanageable) is correct framing. One-schema-per-tenant with 8 filtered views per schema (640 views total, but scripted) is the correct approach. Dynamic view using `current_user` + lookup table (Option B) is an interesting alternative worth noting. Partition design including `business_unit` column alongside `tenant_id` and day is practical for this workload. OPA vs file-based rules comparison (hot-reload vs coordinator restart) is correctly differentiated. Technical accuracy docked: Step 5 `GRANT SELECT ON analytics.events TO ROLE tenant_admin` gives tenant 5001's admin access to the full base table across ALL tenants — the admin of tenant 5001 should only see tenant_id=5001, scoped via a filtered admin view (`WHERE tenant_id = '5001'`), not the base table. This is a cross-tenant data exposure bug. Practical applicability docked: the admin cross-tenant access bug would fail security review. "Trino's default access control is allow-all" oversimplification repeated from Q1. Note about external governance document correctly defers OPA policy rules. HTML entities in code blocks.
