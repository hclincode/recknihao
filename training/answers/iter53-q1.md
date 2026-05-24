# Iter53 Q1 Answer — Resource Groups Match JWT Principals, Not Roles

Your resource group config isn't working because you're probably matching on the wrong field. The key insight: **resource group selectors match the JWT `sub` claim (which becomes your Trino username), not the Trino role name.**

## The problem: confusing roles with resource group selectors

You created per-tenant Trino roles (great for isolation), but **roles and resource groups are completely separate mechanisms.** Assigning a user to a role does nothing for resource group routing. Resource groups need to match on the actual username connecting to Trino — which comes from your JWT token's `sub` claim.

## How JWT maps to Trino identity

Your JWT has a `sub` claim (the subject — typically the service account name, like `"acme-service-account"`). When that JWT authenticates to Trino, Trino extracts the `sub` value and uses it as the Trino username. **This username is what resource group selectors see.**

The other JWT fields (`tenant_id`, `roles` claims) are just additional data in the token — Trino doesn't automatically use them for resource group routing.

## The fix: match selectors on the JWT principal name

In your `etc/resource-groups.json`, use `"userRegex"` to match the JWT `sub` value:

```json
{
  "rootGroups": [
    {
      "name": "global",
      "softMemoryLimit": "80%",
      "hardConcurrencyLimit": 100,
      "maxQueued": 1000,
      "subGroups": [
        {
          "name": "tenant_acme",
          "softMemoryLimit": "20%",
          "hardConcurrencyLimit": 5,
          "maxQueued": 50
        }
      ]
    }
  ],
  "selectors": [
    {
      "userRegex": "acme-service-account",
      "group": "global.tenant_acme"
    },
    {
      "userRegex": ".*",
      "group": "global"
    }
  ]
}
```

The `"userRegex"` field is a Java regex matched against the JWT `sub` value. If your tenant's service account has `sub = "acme-service-account"`, then `"userRegex": "acme-service-account"` is the correct selector. The second selector (`".*"`) is a catch-all for everyone else.

## Why your config is silently failing

If you wrote a selector that matches the Trino role name instead of the JWT principal name, the selector **silently never matches.** Trino doesn't error — it just routes your tenant's queries to the default global pool instead of the custom `tenant_acme` group. That's why the memory limit "isn't doing anything."

Queries that match no selector fall into the default/catch-all pool, completely uncapped.

## Property names you need to use correctly

| Correct name | What it does |
|---|---|
| `softMemoryLimit` | Soft cap on memory (e.g., `"20%"` or `"10GB"`) |
| `hardConcurrencyLimit` | Max concurrent queries in this group (integer) |
| `maxQueued` | Max queries waiting in queue (integer) |
| `userRegex` | Java regex matched against the JWT `sub` / Trino username |

If you use a wrong property name (like `maxMemoryPercent`), the config loads without error but the limit simply won't apply — another silent failure.

## Verify your selector is working

After deploying the config, restart the Trino coordinator. Then check which resource group your tenant's queries are landing in:

```sql
-- Run as an admin user in Trino
SELECT user, query_id, resource_group_id
FROM system.runtime.queries
WHERE user = 'acme-service-account';
```

You should see `resource_group_id` containing your custom group path (e.g., `global.tenant_acme`). If it shows a default/global group instead, your selector is still not matching.

If you need to kill a runaway query from that tenant:

```sql
-- Must use CALL (not SELECT) — kill_query is a procedure, not a function
CALL system.runtime.kill_query(query_id => 'query-id-here', message => 'resource limit exceeded');
```

## Summary

- **Resource groups match on the JWT `sub` claim** (the Trino username/principal), not the Trino role name
- **Use `userRegex` in the selector** — it's a Java regex matched against the JWT `sub` value
- **Silent failures are the norm** — misconfiguration doesn't error, it just routes to the wrong pool
- **Always include a catch-all selector** (`"userRegex": ".*"`) at the bottom so every query has a home
- **Test with `system.runtime.queries`** to verify the `resource_group_id` column shows the right group
