# Iter50 Q1 Answer — Trino resource groups for noisy-neighbor isolation

**Question**: Larger tenant is starving smaller tenants. Memory limit on Trino role didn't help. How to properly cap resource consumption and see who's using the most right now?

---

## Why the role-based memory limit didn't work

A Trino **role** controls what data a user can access — which tables, schemas, and columns. It does NOT control how much CPU or memory a query consumes. Even if you restrict the large tenant's role, they're still authorized to query their own data, and a single large query can consume the entire cluster's memory. Roles are access control; resource consumption is a separate mechanism.

## The solution: Trino Resource Groups

Resource groups create named query queues, each with caps on memory, concurrency, and queue depth. Define them in `etc/resource-groups.json` on the Trino coordinator:

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
          "name": "tenant_large",
          "softMemoryLimit": "20%",
          "hardConcurrencyLimit": 3,
          "maxQueued": 50
        },
        {
          "name": "tenant_default",
          "softMemoryLimit": "60%",
          "hardConcurrencyLimit": 40,
          "maxQueued": 400
        }
      ]
    }
  ],
  "selectors": [
    {
      "user": "large-customer-jwt-subject",
      "group": "global.tenant_large"
    }
  ]
}
```

What this does:
- **`softMemoryLimit: "20%"`** — when the large tenant's queries exceed 20% of cluster memory, new queries queue instead of running immediately
- **`hardConcurrencyLimit: 3`** — at most 3 of the large tenant's queries run simultaneously
- Smaller tenants share the remaining 60% pool and run up to 40 concurrent queries

## Critical gotcha: selectors match JWT principals, not Trino role names

The `"user"` field in `selectors` is matched against the **JWT subject** (the authenticated principal name the tenant uses to connect to Trino). It is NOT the Trino role name. If the large tenant's JWT `sub` claim is `large-customer-svc-account`, the selector must say exactly `"user": "large-customer-svc-account"`. Using the role name instead causes the selector to silently never match — the resource group doesn't apply, the tenant stays uncapped, and there's no error in the logs.

## How to see which tenant is using the most right now

Query `system.runtime.queries` as an admin:

```sql
SELECT 
  user, state, queued_time_ms, execution_time_ms, query
FROM system.runtime.queries
WHERE state IN ('QUEUED', 'RUNNING')
ORDER BY execution_time_ms DESC
LIMIT 20;
```

- High `execution_time_ms` for the large tenant while smaller tenants have high `queued_time_ms` confirms the noisy-neighbor problem
- Once resource groups are deployed, the large tenant's 4th+ queries will show `state = 'QUEUED'` instead of running immediately

**Note**: `system.runtime.queries` is a cross-tenant leak path — it shows every user's SQL text to anyone with access. Only admin accounts should have access to this table; tenant principals must be blocked by OPA or a catalog-level deny rule.

## Immediate relief during an active incident

Kill the offending query now:

```sql
SELECT system.runtime.kill_query(
  query_id => '20260524_134522_00123_abcde',
  message  => 'Throttling per resource limits being deployed'
);
```

This terminates the query immediately and frees cluster resources. Use this during an incident; resource groups prevent the next one.

## Tuning guidance

- Large tenant's `softMemoryLimit`: 15–25% depending on cluster size and their contract
- Large tenant's `hardConcurrencyLimit`: 2–5 is typical for batch jobs
- After deploying, verify in `system.runtime.queries` that smaller tenants' `queued_time_ms` drops to near zero

Resource groups cap resource consumption but don't control data access — your existing view isolation and REVOKE setup still handles that separately.
