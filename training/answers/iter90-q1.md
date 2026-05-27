# Iter90 Q1 — Answer

**Question**: One large tenant's heavy Trino queries are slowing all other tenants' dashboards. Can you cap how much any single tenant can use so smaller tenants always get a fair slice?

---

## Answer

Yes, Trino has exactly what you need: **resource groups**, a feature specifically designed to prevent one tenant's heavy queries from starving the others. On your stack (Trino 467), you can define per-tenant resource limits that cap CPU, memory, and concurrent queries for each customer.

## The problem: "noisy neighbor"

When one of your largest enterprise tenants kicks off a 12-month report while 79 other tenants are querying the same cluster, that big query consumes most of your workers' CPU and memory. The smaller tenants' dashboard queries get queued, and by the time one finishes executing, they timeout because they've been waiting 5+ minutes just to start running.

Resource groups solve this by creating **named query admission queues** with per-tenant caps.

## How it works in plain terms

Think of it like lanes on a highway. Without resource groups: one massive truck takes all the lanes and smaller cars get stuck behind it. With resource groups: you reserve "lane 1 for tenant Acme" with a speed limit, "lane 2 for tenant Beta" with its own speed limit, etc. Each tenant's queries run in their designated lane and never block the others.

## Configuration for your 80-tenant setup

Here's the configuration file (`etc/resource-groups.json`) you'd put on your Trino coordinator:

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
          "name": "tenant_enterprise",
          "softMemoryLimit": "30%",
          "hardConcurrencyLimit": 10,
          "maxQueued": 50
        },
        {
          "name": "tenant_standard",
          "softMemoryLimit": "15%",
          "hardConcurrencyLimit": 5,
          "maxQueued": 25
        },
        {
          "name": "internal_analytics",
          "softMemoryLimit": "35%",
          "hardConcurrencyLimit": 20,
          "maxQueued": 100
        }
      ]
    }
  ],
  "selectors": [
    {
      "user": "acme-service-account",
      "group": "global.tenant_enterprise"
    },
    {
      "user": "beta-service-account",
      "group": "global.tenant_standard"
    },
    {
      "user": "data-team",
      "group": "global.internal_analytics"
    }
  ]
}
```

**What each parameter does:**

- **`softMemoryLimit`**: When a group hits this limit, new queries are paused (queued) instead of running immediately.
- **`hardConcurrencyLimit`**: Maximum queries that can run simultaneously in that group. If Acme hits 10 concurrent queries, the 11th query waits in the queue (doesn't consume cluster CPU yet).
- **`maxQueued`**: How many queries can wait in that group's queue before new submissions fail. Prevents the queue from growing unbounded.

**Real scenario with your config above:**
- Tenant Acme (the big enterprise) has `hardConcurrencyLimit: 10` — they can run at most 10 queries at the same time, and they get 30% of total cluster memory.
- Tenant Beta and all the others have `hardConcurrencyLimit: 5` — 5 concurrent queries, 15% memory each.
- When Acme's 12-month report starts running and hits that 30% memory cap, their next query queues. Meanwhile, Beta's dashboard queries start immediately in their own 15% memory slice — they never get starved because the queuing is *per-tenant*, not cluster-wide.

## Important production detail: JWT principal matching

The resource group configuration file uses **JWT principal names** (the authenticated identity) to match which tenant gets which limits. The `"user"` field in the selector must match the JWT `sub` claim exactly — usually something like `"acme-service-account"`. **This is the most common misconfiguration**: if you name the selector `"user": "acme_role"` but the JWT principal is `acme-service-account`, the resource group silently never applies and your tenant remains uncapped.

## How to deploy this

1. Update the ConfigMap or config file on your Trino coordinator with the `resource-groups.json` above.
2. **Restart the Trino coordinator pod** — resource group configuration requires a restart to take effect (not hot-reloaded from file).
3. During restart, all in-flight queries fail with a connection error (typically 10–30 second outage). Schedule this during a low-traffic window.
4. After restart, new queries from each tenant are automatically routed to their resource group.

## If you need to tune limits without a restart

File-based configuration requires a restart for each change. Trino also supports a **database-backed resource group manager** that hot-reloads every 1 second from a Postgres or MySQL database. Changes take effect within seconds — no restart. Worth it if you're actively managing per-tenant caps based on observed traffic.

## Immediate relief during an active incident

If right now Acme's 12-month query is crushing your cluster and you can't wait for a config change, kill the offending query:

```sql
-- Run as admin in Trino. Get the query_id from the Trino UI.
CALL system.runtime.kill_query(
  query_id => '20260525_142332_00456_abcde',
  message  => 'Throttling for cluster stability'
);
```

This terminates the query immediately and frees resources. Then deploy the resource groups config at the next maintenance window.
