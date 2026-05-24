# Score: iter53-q1

**Topic**: Multi-tenant analytics: resource group selectors
**Score**: 3.50 / 5.0

## What the answer got right
- Correctly identifies the root cause: resource group selectors match the JWT-derived principal (the Trino username), not the Trino role name. This is the core insight the engineer needed.
- Correctly states the JWT `sub` claim is what Trino uses as the username/principal by default.
- Correctly distinguishes between roles and resource groups as separate mechanisms — assigning a role does not route a user into a resource group.
- Correctly explains silent failure mode: a selector that doesn't match silently routes to the default group (no error).
- Correctly recommends a catch-all selector (`.*`) at the end so every query has a home.
- Includes a runnable verification query against `system.runtime.queries` showing `resource_group_id` — actionable next step.
- Correctly notes wrong property names (e.g., `maxMemoryPercent`) load silently without error — useful defensive callout.
- Uses correct property names `softMemoryLimit`, `hardConcurrencyLimit`, `maxQueued`, matching the resource at lines 442-449 and the official Trino docs.
- JSON example is structurally valid for Trino resource groups (rootGroups + subGroups + selectors hierarchy).

## Gaps or errors
- **CRITICAL — wrong JSON field name.** The answer uses `"userRegex"` as the selector field name in the JSON example and in the "Property names" table. The actual Trino JSON field is named **`"user"`** (verified against trino.io/docs/current/admin/resource-groups.html and the resource file lines 484-496, which use `"user"` correctly). The field accepts a Java regex as its value, but the field name itself is `user`, not `userRegex`. An engineer copy-pasting this JSON will get a selector that silently fails to match anything — the exact failure mode the answer claims to be fixing. This contradicts the project's own resource file and the official Trino docs.
- The answer never mentions the production stack uses **OPA** for authorization (per `prod_info.md`); while resource groups themselves are separate from OPA, the answer would be stronger if it noted that JWT principal extraction is governed by the JWT authenticator config and that authorization is handled by OPA — context the engineer needs.
- No mention of `originalUser`, `authenticatedUser`, or `userGroup` as alternative selector fields, nor `clientTags` / `source` as alternative routing options (these are listed in the expected criteria).
- No mention of `query.max-memory-per-node` as a per-query hard cap that complements resource groups (listed in expected criteria).
- The `kill_query` digression at the bottom is useful but tangential to the question, which was about why the selector isn't matching.

## Verdict
The conceptual answer (JWT sub becomes Trino username; selectors match the principal, not the role) is correct and directly addresses the engineer's confusion, but the JSON code example contains a fabricated field name (`userRegex` instead of `user`) that will reproduce the exact "silent no-match" failure the engineer is trying to fix — making this answer a net-negative for an engineer who copies the snippet.
