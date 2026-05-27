# Judge — Iter 107 Q1

**Topic**: Multi-tenant analytics
**Score**: 4.75 / 5 (Tech 5.0, Clarity 4.5, Practical 5.0, Completeness 4.5)

## Verdict
Strong, well-targeted answer. It correctly identifies per-tenant principal isolation as the standard pattern, explains why per-tenant views (with baked-in WHERE) are the actual enforcement boundary, and correctly maps the "smarter way" onto the production JWT+OPA stack instead of inventing 80 hand-managed roles. SQL snippets, the onboarding checklist, and the CI isolation test block make the recommendation immediately actionable.

## What was verified correct (via WebSearch)
- Trino `CREATE VIEW` defaults to `SECURITY DEFINER` — confirmed on Trino docs (current). Body executes with the view owner's privileges; invoker only needs SELECT on the view.
- `CREATE SCHEMA IF NOT EXISTS schema_name` — confirmed valid syntax in Trino docs.
- Resource groups two-file layout is correct: `etc/resource-groups.properties` sets `resource-groups.configuration-manager=file` and points at `resource-groups.config-file=etc/resource-groups.json`. The JSON shape (`rootGroups`, `softMemoryLimit`, `hardConcurrencyLimit`, `subGroups`, `selectors`) matches the documented schema.
- `REVOKE ALL PRIVILEGES ON <table> FROM USER <user>` is valid Trino SQL (per the REVOKE privilege page).
- `system.runtime.queries` defaults to letting all users see all queries unless a system access control restricts it; OPA / file-based query rules can deny `system.*` to tenant principals.
- Iceberg `$partitions` / `$files` metadata tables are real and exposed by the Iceberg connector; access is governed by the same connector/access-control plumbing, so OPA can deny `$`-suffix table access.
- JWT-claim → OPA principal mapping framing is consistent with Trino's OPA access control plugin documentation.
- Correctly defers specific OPA policy content to the external governance document (matches `prod_info.md` guidance).

## Errors or gaps
- Minor: implies OPA can match table names by `$`-suffix as a class. In practice OPA receives the full table name in the request input and the policy must do the suffix check; this is achievable but slightly hand-waved in the answer.
- Minor: doesn't mention the alternative low-effort guardrail (Trino session property carrying `tenant_id` + a query-rewrite proxy / view-only catalog) for teams that aren't ready for full per-principal rollout. Not required, but a more complete "is there a smarter way" would touch it.
- Minor: doesn't mention HTTP `X-Trino-User` / impersonation as the actual mechanism by which a backend can present per-tenant identities to Trino over a single connection pool — an engineer reading this might still wonder "do I literally open 80 JDBC connections?"

## Resource fix recommendations
- LOW: in `resources/05-multi-tenant-analytics.md`, add a short note clarifying how a single backend service presents per-tenant identity to Trino (JWT subject / `X-Trino-User` impersonation header) so engineers understand they aren't maintaining 80 connection pools.
- LOW: add a one-paragraph contrast with the "single service account + session property + query-rewrite proxy" pattern, with a recommendation to prefer per-principal + OPA for production but acknowledge the lighter pattern exists.

## Updated topic state
- Multi-tenant analytics: 102 questions / running avg 4.455
