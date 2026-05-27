# Judge Score — Iter135 Q2

**Score**: 3.75 / 5 (Tech 3, Clarity 5, Practical 4, Completeness 3)

## Verdict
The answer is well-structured, conceptually sound on the "OPA works alongside views, not as a replacement" framing, correctly identifies SECURITY DEFINER as the default Trino view mode, and accurately describes row-filter mode as an extension beyond basic allow/deny. However, it contains a HIGH-severity factual error: the example OPA input payload shows a `claims` field inside `input.context.identity`, but the official Trino OPA access control documentation explicitly lists the identity object as containing only `user` and `groups`. JWT claims are NOT passed to OPA on Trino 467. This misleads the engineer into thinking they can read `input.context.identity.claims.tenant_id` directly in Rego, which would silently fail in production.

## Technical claims verified
- OPA as Trino system access control via `access-control.name=opa` — CORRECT (per Trino OPA docs).
- OPA input contains `context.identity.claims.tenant_id` (JWT claims) — INCORRECT. Trino docs confirm identity has only `user` and `groups`. The PR (#22944) adding JWT claims to Identity was still unmerged as of late 2025 and does not expose claims to OPA. The engineer would need to either (a) put tenant_id in the username (e.g., `user-acme@tenant`) and parse in Rego, (b) map user→tenant via OPA data documents/bundles, or (c) configure JWT groups extraction (also not natively supported in Trino — see issue #28571).
- Trino view default = SECURITY DEFINER (executes with view owner's privileges) — CORRECT.
- OPA standard allow/deny cannot enforce row-level filtering — CORRECT.
- Row-filter mode via `opa.policy.row-filters-uri` returning `{"expression": "clause"}` objects — CORRECT (matches docs).
- Iceberg metadata table protection (`$partitions`, `$files`, `$snapshots`) via OPA — CORRECT and a valuable operational call-out.
- Defense-in-depth three-layer pattern (view WHERE + role grant + OPA deny) — Conceptually CORRECT, though "role grant" layer is misleading in this environment because the prod stack uses OPA as the authorization backend (not file-based or SQL GRANT). The role grant layer effectively collapses into OPA.

## Errors or gaps
- **HIGH**: The JSON example showing `"claims": {"tenant_id": "acme", ...}` in `input.context.identity` is fabricated. The Trino OPA plugin does not pass JWT claims into the identity payload on Trino 467. An engineer copying this Rego pattern would build a policy that silently never matches and either fails-open or denies all queries.
- **MEDIUM**: The answer never acknowledges the actual workaround patterns used in production (encode tenant in username/principal, OPA data bundle mapping user→tenant, or wait for upstream Trino support). It also doesn't mention the open Trino issue/PR explicitly so the engineer can track it.
- **MEDIUM**: The answer mixes general Trino RBAC (`GRANT SELECT ON ... TO role_acme`) with the OPA-backed production setup. In the production stack described in prod_info.md, OPA replaces file-based and SQL-grant-based authorization — there is no separate "role grant layer" to coexist with OPA. The three-layer model should be: view WHERE clause + OPA deny on base table + OPA deny on system/metadata tables.
- **LOW**: No mention that per prod_info.md, specific OPA policies and role hierarchies are defined in an external governance document, so the engineer should coordinate with the platform team on the exact tenant-identification mechanism currently used.
- **LOW**: SECURITY DEFINER caveat about ignored roles (per Trino issue #10708) — not raised, but relevant to the "view owner grant" discussion.

## Resource fix recommendations
- Update the OPA/Trino resource (likely `resources/` Trino auth or OPA file) to:
  1. Correct the OPA input schema example — show only `{"user": "...", "groups": [...]}` inside `input.context.identity`. Remove the `claims` field from the JSON example.
  2. Add a clear callout: "Trino does NOT pass JWT claims into the OPA input as of Trino 467/current. To use tenant_id in policy, either (a) bake tenant into the username/principal and parse in Rego, or (b) maintain a user→tenant mapping in an OPA data bundle. Track Trino PR #22944 for native JWT claim passthrough."
  3. Adjust the defense-in-depth layering to reflect the production stack: view WHERE + OPA base-table deny + OPA system/metadata deny — not SQL GRANT roles.
  4. Add a brief note that specific OPA policies belong in the external governance document (per prod_info.md) and the engineer should confirm the tenant-identification convention with the platform team.
