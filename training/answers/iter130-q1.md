# Iter130 Q1 — Answer

**Question**: We're running Trino on-prem and lately I've been noticing that some dashboard queries just sit there for a while before they actually start running. When I look at the Trino UI, they show up as "queued." What's going on there? Is Trino just overwhelmed, or is there some kind of configuration that controls how many queries can run at once? I ask because we have a mix of quick dashboard loads (should feel instant) and these big export jobs that one customer kicks off and they seem to be hogging everything. Is there a way to set it up so the big heavy jobs don't block everyone else?

---

## Your Trino Queueing Problem and What's Happening

The "Queued" state means **queries are waiting for worker slots to become available**. You have two problems running together:

1. **Concurrency saturation** — more queries are trying to run simultaneously than your cluster can handle.
2. **No workload isolation** — big export jobs share worker resources with dashboard queries and compete directly.

The fix is **Trino resource groups** — a configuration mechanism that creates separate "lanes" for different workloads. Dashboards get one lane, exports get another, and they no longer block each other.

---

## How Resource Groups Work

Think of resource groups as **priority queues with capacity limits**. You define:
- Which queries go into which group (via principal/user matching in selectors)
- How many queries in that group can run simultaneously (`hardConcurrencyLimit`)
- How much memory the group can use (`softMemoryLimit`)
- How many queries can wait in that group's queue (`maxQueued`)
- How to schedule between groups (`schedulingWeight`)

---

## Configuration: Two Files Required

**File 1: `/etc/trino/resource-groups.properties`** (exactly 2 lines):

```properties
resource-groups.configuration-manager=file
resource-groups.config-file=etc/resource-groups.json
```

This tells Trino where to find the actual config. **Without this file, the JSON is dead config** — no warning, no error, just silent inertia.

**File 2: `/etc/trino/resource-groups.json`**:

```json
{
  "cpuQuotaPeriod": "1h",
  "rootGroups": [
    {
      "name": "global",
      "softMemoryLimit": "80%",
      "hardConcurrencyLimit": 100,
      "maxQueued": 1000,
      "schedulingPolicy": "weighted_fair",
      "subGroups": [
        {
          "name": "dashboards",
          "softMemoryLimit": "30%",
          "hardConcurrencyLimit": 20,
          "maxQueued": 100,
          "schedulingWeight": 10
        },
        {
          "name": "exports",
          "softMemoryLimit": "50%",
          "hardConcurrencyLimit": 3,
          "maxQueued": 50,
          "schedulingWeight": 1
        }
      ]
    }
  ],
  "selectors": [
    {
      "user": "acme-service-account",
      "source": ".*dashboard.*",
      "group": "global.dashboards"
    },
    {
      "user": "acme-service-account",
      "source": ".*export.*",
      "group": "global.exports"
    },
    {
      "user": "acme-service-account",
      "group": "global.dashboards"
    }
  ]
}
```

**What this does:** Dashboard queries get up to 20 concurrent runs with weight 10 (preferred). Exports get only 3 concurrent runs with weight 1. When both have queued work, Trino admits dashboard queries 10:1 over exports.

---

## Property Names: Where Most Teams Get It Wrong

| What you want | Correct property | Common WRONG name |
|---|---|---|
| Max queries running at once | `hardConcurrencyLimit` | ~~`maxRunning`~~ (does not exist) |
| Memory cap | `softMemoryLimit` | ~~`maxMemoryPercent`~~ (does not exist) |

If you write incorrect property names, the file loads without error but the limits **silently never apply**. The only way to know is to check the Trino UI.

---

## Per-Tenant Isolation (For Your Multi-Tenant SaaS)

Extend to one group per customer:

```json
{
  "rootGroups": [{
    "name": "global",
    "softMemoryLimit": "80%",
    "hardConcurrencyLimit": 100,
    "subGroups": [
      {"name": "tenant_a", "softMemoryLimit": "20%", "hardConcurrencyLimit": 5},
      {"name": "tenant_b", "softMemoryLimit": "20%", "hardConcurrencyLimit": 5},
      {"name": "internal", "softMemoryLimit": "20%", "hardConcurrencyLimit": 10}
    ]
  }],
  "selectors": [
    {"user": "tenant-a-account", "group": "global.tenant_a"},
    {"user": "tenant-b-account", "group": "global.tenant_b"},
    {"user": "data-team", "group": "global.internal"}
  ]
}
```

Each tenant's heavy exports now can't block another tenant's dashboards.

---

## Deployment: Coordinator Restart Required

**File-based resource groups require a Trino coordinator restart — no hot-reload.**

```bash
kubectl rollout restart deployment/trino-coordinator -n <namespace>
kubectl rollout status deployment/trino-coordinator -n <namespace>
```

Expect 30–60 seconds of downtime. All in-flight queries are killed. Plan this for a maintenance window. Queries submitted after the new coordinator is Ready run under the new limits.

---

## Verify Selectors Are Working

After restart, check which group queries landed in:

```sql
SELECT query_id, user, state, resource_group_id, query
FROM system.runtime.queries
WHERE state IN ('RUNNING', 'QUEUED')
ORDER BY created DESC;
```

`resource_group_id` shows the full path — e.g., `ARRAY['global', 'dashboards']` or `ARRAY['global', 'exports']`. If all queries land in `ARRAY['global']` instead of a subgroup, the selector didn't match — usually because the JWT principal doesn't exactly match the `"user"` regex.

---

## Live Incident: Kill the Runaway Query Now

If one export is starving everyone **right now**, kill it immediately while you're rolling out the config:

```sql
CALL system.runtime.kill_query(
  query_id => '20260526_143012_00042_abcde',
  message  => 'Throttling — export blocking dashboards'
);
```

Then push the new resource groups config and restart. Don't skip the kill — new limits can't retroactively constrain a query that's already running.

---

## Optional: CPU Limits for Expensive Workloads

If exports are CPU-intensive, add a CPU cap:

```json
{
  "name": "exports",
  "softMemoryLimit": "50%",
  "hardConcurrencyLimit": 3,
  "softCpuLimit": "2h",
  "hardCpuLimit": "3h"
}
```

This caps the exports group to 3 CPU-hours per rolling `cpuQuotaPeriod` window. When exceeded, the next export query queues until the window advances.
