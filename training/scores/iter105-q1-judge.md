# Judge — Iter 105 Q1

**Topic**: Multi-tenant analytics
**Score**: 4.5 / 5 (Tech 4.0, Clarity 5.0, Practical 5.0, Completeness 4.0)

## Verdict
A strong, well-structured answer that correctly frames the core mental shift ("never rely on the application layer once you have a separate analytics system") and walks the engineer through views + OPA + resource groups + CI tests end-to-end. The technical content is largely accurate and aligned with the on-prem Trino 467 + OPA + Iceberg stack described in prod_info.md. A few minor issues — most importantly, the resource-groups config snippet is placed in the wrong filename, and the GRANT/REVOKE-driven SQL story is slightly muddled given OPA is the actual enforcement backend in this environment.

## What was verified correct (via WebSearch)
- Trino views default to SECURITY DEFINER — view body runs with the view owner's privileges, not the invoker's. Verified at trino.io/docs/current/sql/create-view.html.
- `REVOKE ALL PRIVILEGES ON <table> FROM USER <user>` is valid Trino SQL. Verified at trino.io/docs/current/sql/revoke.html.
- `CREATE SCHEMA IF NOT EXISTS <name>` is valid Trino syntax. Verified at trino.io/docs/current/sql/create-schema.html.
- Iceberg metadata tables (`$partitions`, `$files`, `$snapshots`, `$manifests`, `$history`, `$refs`) exist and expose internal table structure that includes cross-tenant aggregates (min/max per partition, file paths, row counts) — correctly flagged as a leak vector. Verified at trino.io/docs/current/connector/iceberg.html.
- `system.runtime.queries` exposes SQL text and user identity of recently running queries cluster-wide — correctly flagged as a cross-tenant leak risk. Verified at trino.io/docs/current/connector/system.html.
- Partitioning Iceberg tables by `(tenant_id, day(event_ts))` for file-level pruning — sound design.
- "Deny takes precedence" model when OPA is the authz backend — consistent with Trino's system access control evaluation order.

## Errors or gaps
- **Resource-groups file location is wrong**: The answer puts the JSON config in `etc/resource-groups.properties`. The actual layout is: `etc/resource-groups.properties` is a Java properties file containing `resource-groups.configuration-manager=file` and `resource-groups.config-file=etc/resource-groups.json`; the JSON snippet shown belongs in `etc/resource-groups.json`. This will fail copy-paste in production.
- **GRANT/REVOKE narrative is awkward for an OPA-backed environment**: prod_info.md says OPA is the authorization backend. The answer goes deep on Trino SQL GRANT/REVOKE/CREATE ROLE as if they drive enforcement, but when OPA is configured, OPA policy is the source of truth and SQL GRANTs are at best advisory or unused. The answer should call out that the SQL RBAC commands are illustrative and that real enforcement is OPA policy authored in the external governance document.
- **Slight overclaim on REVOKE necessity**: "Trino allows access by default" is misleading. In Trino, table privileges default to the owner; a freshly minted service-account user has no grants unless explicitly given. The defensive REVOKE is fine, but the rationale stated isn't quite right.
- **Defers OPA Rego to "external governance document"** — this is correct per prod_info.md, but the answer could state the deferral more explicitly (it brushes past it in one sentence). Acceptable as-is.
- **Did not flag the JWT auth dimension**: the principal that OPA sees comes from the JWT — worth mentioning briefly that the tenant identifier needs to be a stable claim in the JWT for OPA rules to key off it. Minor completeness gap.

## Resource fix recommendations
- **MEDIUM**: Fix the resource-groups example in resources/ to show the proper two-file layout (`etc/resource-groups.properties` pointing at `etc/resource-groups.json`). The current answer pattern would mislead engineers into pasting JSON into a `.properties` file.
- **MEDIUM**: Add a short paragraph to the multi-tenant resource clarifying that in an OPA-backed Trino deployment, SQL GRANT/REVOKE statements are illustrative; the real enforcement happens via OPA policy in the external governance document. The view-as-isolation-boundary pattern is still correct, but the role/grant SQL is conceptual.
- **LOW**: Add a one-line note tying JWT claims to OPA principal/tenant identification, so engineers understand how their auth service feeds the policy decision.

## Updated topic state
- Multi-tenant analytics: 100 questions / running avg 4.447
  - (4.447 * 99 + 4.5) / 100 = 4.44753 → **4.448**
