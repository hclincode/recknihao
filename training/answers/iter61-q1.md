# Iter61 Q1 — Answer

**Question**: We have Trino running on-prem and lately I've been getting paged because some tenants are complaining their dashboard queries are taking forever. When I look at the Trino UI, I can see a handful of queries from one particular tenant that are all queued or running, and they're huge — scanning billions of rows. Meanwhile smaller tenants are just sitting there waiting. Someone on the team mentioned we should configure "resource groups" to stop one tenant from hogging everything. I looked at the config and I see fields like `maxConcurrentQueries`, `maxQueued`, and something called `"user"` with a regex pattern. But I don't really understand how Trino knows which query belongs to which tenant, or how the regex connects to that. And if I'm on call and this is happening right now — like a tenant is actively killing performance for everyone else — what do I actually do? Do I kill their queries manually? Change config on the fly? How do I even figure out which resource group a running query is in?

---

## Answer

Resource groups are your steady-state prevention tool. `CALL system.runtime.kill_query()` is your emergency relief tool for live incidents. Here's how to use both.

### Right now: immediate on-call steps

**Step 1: Kill the offending queries (takes 30 seconds)**

Connect as a Trino admin and find the offending queries:

```sql
SELECT query_id, user, state, query
FROM system.runtime.queries
WHERE state IN ('RUNNING', 'QUEUED')
ORDER BY created DESC;
```

Find the tenant's query IDs (they'll all share the same `user` value, like `tenant-xyz-svc`). Kill each one:

```sql
CALL system.runtime.kill_query(
  query_id => '20260525_091234_00001_xyz',
  message  => 'Excessive resource usage, see incident #XXXX'
);
```

This terminates the query immediately and returns cluster resources. The tenant gets an error; everyone else gets their capacity back. Do this first — it's the emergency relief valve.

**Step 2: Deploy resource group limits (permanent fix)**

While the cluster is recovering, prepare the config. Edit `etc/resource-groups.json` on the Trino coordinator:

```json
{
  "rootGroups": [{
    "name": "global",
    "softMemoryLimit": "80%",
    "hardConcurrencyLimit": 100,
    "maxQueued": 1000,
    "subGroups": [
      {
        "name": "tenant_noisy",
        "softMemoryLimit": "10%",
        "hardConcurrencyLimit": 2,
        "maxQueued": 10
      },
      {
        "name": "tenant_standard",
        "softMemoryLimit": "15%",
        "hardConcurrencyLimit": 5,
        "maxQueued": 50
      },
      {
        "name": "internal_admin",
        "softMemoryLimit": "40%",
        "hardConcurrencyLimit": 15,
        "maxQueued": 200
      }
    ]
  }],
  "selectors": [
    {
      "user": "problematic-tenant-svc-account",
      "group": "global.tenant_noisy"
    },
    {
      "user": ".*-service-account",
      "group": "global.tenant_standard"
    },
    {
      "user": "data-team",
      "group": "global.internal_admin"
    }
  ]
}
```

Push to the coordinator pod (via ConfigMap on Kubernetes). Changes take effect for **new** queries only — that's why you kill the running ones first.

### How Trino knows which query belongs to which tenant

The connection happens at authentication time, not query time:

1. The tenant's app connects to Trino with a JWT token.
2. The JWT's `sub` claim contains the service account name — e.g., `acme-service-account`.
3. Trino extracts this as the **principal** (authenticated identity).
4. When the query runs, `system.runtime.queries.user` shows `acme-service-account`.
5. The resource group selector matches that value against the `"user"` regex. First match wins.

The `"user"` field is a **Java regex** matched against the JWT principal name — not a Trino role name. `".*-service-account"` matches any principal ending with `-service-account`. A specific name like `"acme-service-account"` matches exactly that.

### Critical: use the correct field names

Trino silently ignores unknown property names. The config loads fine, no errors appear, but limits never apply. This is the #1 cause of "resource groups don't seem to work."

| Correct name | Wrong names that Trino silently ignores |
|---|---|
| `hardConcurrencyLimit` | ~~`maxConcurrentQueries`~~, ~~`maxRunning`~~, ~~`maxConcurrent`~~ |
| `softMemoryLimit` | ~~`maxMemory`~~, ~~`maxMemoryPercent`~~, ~~`maxMemoryLimit`~~ |
| `maxQueued` | (this one is correct) |
| `hardCpuLimit` | ~~`maxCpuPercent`~~ (Trino has no such field) |

Your config mentioned `maxConcurrentQueries` — that's one of the silent-ignore names. The working version is `hardConcurrencyLimit`.

### How to see which resource group a running query is in

There's no direct query for this, but you can infer it:

```sql
-- Find all running/queued queries and their users
SELECT query_id, user, state
FROM system.runtime.queries
WHERE state IN ('RUNNING', 'QUEUED');
```

Cross-reference the `user` value against your `resource-groups.json` selectors. Whichever selector matches first determines the group. If `user = 'tenant-xyz-svc'` and your selector says `"user": "tenant-xyz-svc"` → `"group": "global.tenant_xyz"`, that query is in `global.tenant_xyz`.

The Trino Web UI also shows resource group assignment under each query's detail view — click the query ID to see which group it's routing through.

### After the incident: prevention

**Tune limits per tier.** Premium tenants: `hardConcurrencyLimit: 10, softMemoryLimit: "25%"`. Standard: `hardConcurrencyLimit: 5, softMemoryLimit: "15%"`. Free tier: `hardConcurrencyLimit: 2, softMemoryLimit: "5%"`.

**Verify selector matching.** The selector `"user"` value must match the exact JWT principal name in `system.runtime.queries`. If you're unsure, run a test query as that service account, check `system.runtime.queries`, and confirm the `user` column contains what you expect.

**Automate onboarding.** Add selector generation to your tenant onboarding script — when a new customer signs up, auto-generate their resource group entry. This prevents manual typos in service account names.

**Monitor proactively.** Add a dashboard that shows concurrency usage per resource group vs their `hardConcurrencyLimit`. When a group approaches its cap, you know before the pager fires.
