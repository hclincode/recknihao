# Answer to Q1: Trino Per-Tenant Resource Limits via Resource Groups (Iter 333)

Yes — Trino has a built-in feature called **resource groups** designed precisely for this: capping memory and concurrency per customer with different limits per tier, all on a single shared cluster.

## How Resource Groups Work

Resource groups act like lanes on a highway: you define how many queries can run simultaneously in each lane, how much memory each lane can use, and which queries go into which lane (via selectors). When a customer's query tries to exceed its lane's limits, it queues instead of running — but it does NOT starve your other tenants.

## The Three Types of Limits

- `softMemoryLimit` — soft cap on total group memory; when exceeded, new queries queue instead of running
- `hardConcurrencyLimit` — cap on simultaneous running queries
- `maxQueued` — how many can wait before new submissions are rejected

## Configuration

Two files needed on the Trino coordinator:

**`etc/resource-groups.properties`:**
```properties
resource-groups.configuration-manager=file
resource-groups.config-file=etc/resource-groups.json
```

**`etc/resource-groups.json`:**
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
          "name": "free_tier",
          "softMemoryLimit": "10%",
          "hardConcurrencyLimit": 2,
          "maxQueued": 10
        },
        {
          "name": "enterprise_tier",
          "softMemoryLimit": "40%",
          "hardConcurrencyLimit": 10,
          "maxQueued": 100
        }
      ]
    }
  ],
  "selectors": [
    { "user": "free-customer-.*", "group": "global.free_tier" },
    { "user": "enterprise-customer-.*", "group": "global.enterprise_tier" },
    { "group": "global" }
  ]
}
```

The `selectors` array routes queries based on username. Your JWT tokens carry the username — free-tier customers land in the free tier group with tighter limits; enterprise customers get looser limits.

## Diagnosing Which Group a Query Is In

```sql
SELECT query_id, user, state, resource_group_id
FROM system.runtime.queries
WHERE state IN ('RUNNING', 'QUEUED');
```

`resource_group_id` shows the path (e.g., `ARRAY['global', 'free_tier']`).

## Important Operational Notes

1. **File-based resource groups require a coordinator restart** to take effect — editing the JSON file alone changes nothing.
2. **For live incidents:** Kill the runaway query first (`CALL system.runtime.kill_query(...)`), then deploy the updated config and restart.
3. **Hot-reload alternative:** `resource-groups.configuration-manager=db` (database-backed) refreshes every 1 second without restart, but requires an extra Postgres/MySQL dependency.
4. **Your stack uses JWT auth** — ensure selectors match exactly what your JWT authenticator produces as the username.

**Resources cited:** `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md`
