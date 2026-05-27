# Iter 198 Q1 Judge — Multi-Tenant Federation Isolation

## Score
| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.63** |

## Verdict
PASS (threshold: 4.5 for Trino federation topic)

## Key findings

**Correct and well-supported claims (verified against trino.io docs):**
- OPA row-filter mode does exist and works as described. `opa.policy.row-filters-uri` returns objects of the form `{"expression": "..."}`, and Trino's analyzer appends each as a WHERE predicate before execution. Source: https://trino.io/docs/current/security/opa-access-control.html.
- OPA enforcement is scoped to Trino only — bypassed by direct Postgres connections. Correctly flagged.
- The answer correctly notes that the injected `WHERE tenant_id = '...'` will be pushed down through the PostgreSQL connector (Trino predicate pushdown applies to predicates added by the analyzer, including OPA row filters).
- The distinction between view-based isolation and RLS is correct: RLS enforces at the storage engine on every row, views are schema-level artifacts whose strength depends on revoking base-table grants. Verified against PostgreSQL docs and multiple multi-tenant RLS references.
- CI verification pattern (`SELECT DISTINCT tenant_id` as tenant principal, expect one row; as admin, expect all) is the right production safeguard.
- PgBouncer + per-role CONNECTION LIMIT advice for the PostgreSQL connector is sound production guidance.

**Minor inaccuracies / oversimplifications:**
- The answer says "OPA sees only the Trino username and groups, not tenant identity in the JWT claims" and then in the implementation section says "OPA receives only the Trino username (what the JWT authenticator extracted), not JWT claims." The first phrasing is more accurate — OPA's context input includes both `identity.user` and `identity.groups`. The later wording understates that groups are also available. A more precise statement: groups *can* be passed if Trino is configured with a group provider, but Trino does not natively parse JWT group claims (open issue #28571). This nuance matters because some shops use the group provider as the tenant carrier.
- "Trino 467's OPA integration" — version-specific phrasing is acceptable for the on-prem stack (Trino 467 is the production version per prod_info.md), but the behavior described is the same in all current Trino releases (467 through 481).
- The Postgres-views section is slightly muddled: it correctly says views provide weaker isolation than OPA enforcement, but the reasoning ("Trino does not coordinate with Postgres-level GRANTs") could be clearer that the protection still works at the Postgres side — what Trino can't do is *enforce* it; that's the point of defense-in-depth.

**Coverage of the four key angles asked about:**
- OPA enforcement scope — covered.
- Postgres-side bypass risk — explicitly called out.
- Tenant identity encoding (JWT → Trino username or OPA data bundle) — covered well, with concrete examples.
- Testing — covered with a specific, runnable CI assertion.

**Fit with production environment (prod_info.md):**
- Correctly accounts for JWT authentication, OPA authorization, on-prem stack, Trino 467.
- Appropriately defers specific OPA policy rule content (per the external governance document guidance) while still explaining the *mechanism* — exactly what prod_info.md asks judges to look for.
- Does not invent specific role hierarchies or policy rules.

## Resource fix suggestions

1. In `resources/22-trino-federation-postgresql.md`, clarify that OPA's context input includes both `identity.user` and `identity.groups`, and that groups can carry tenant identity if a group provider is configured. Note that Trino does not natively parse JWT group claims (Trino issue #28571) — this is the real reason tenant identity often has to be carried in the username or an external OPA data bundle in the production stack.
2. In `resources/05-multi-tenant-analytics.md`, consider adding a short subsection comparing Postgres RLS vs `SECURITY INVOKER` views vs `SECURITY DEFINER` views for the federated multi-tenant case. The current resource touches on views but does not give a crisp side-by-side for the "Trino federating Postgres" scenario.
3. Consider documenting that OPA-injected row-filter predicates are eligible for predicate pushdown into the PostgreSQL connector (this is implicit but worth stating explicitly so engineers understand the performance behavior — only the tenant's rows are pulled from Postgres, not the full table).
