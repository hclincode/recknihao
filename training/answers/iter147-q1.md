# Iter 147 Q1 — Trino Resource Groups for Tenant Isolation

## Answer

Yes — Trino has a built-in mechanism called **resource groups** that lets you enforce strict limits on per-tenant memory, CPU, and concurrent query slots. This is exactly what you need to prevent one customer's large export from starving everyone else.

### The problem you've hit

When one tenant runs a large export query, all tenants share the same Trino cluster — the same workers, the same CPU, the same memory. A 6-month export can pin every worker at high utilization for the duration, queuing everyone else's dashboard queries behind it. This is a compute contention issue, not a storage isolation issue. Resource groups fix the compute side.

### Resource groups configuration

You define resource groups in two files on the Trino coordinator:

**File 1: `etc/resource-groups.properties`** (pointer to the config file):
```properties
resource-groups.configuration-manager=file
resource-groups.config-file=etc/resource-groups.json
```

**File 2: `etc/resource-groups.json`** (the actual limits):

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
          "name": "large_customer_exports",
          "softMemoryLimit": "30%",
          "hardConcurrencyLimit": 2,
          "maxQueued": 20,
          "softCpuLimit": "4h"
        },
        {
          "name": "small_tenants",
          "softMemoryLimit": "50%",
          "hardConcurrencyLimit": 50,
          "maxQueued": 500
        },
        {
          "name": "internal_admin",
          "softMemoryLimit": "40%",
          "hardConcurrencyLimit": 10
        }
      ]
    }
  ],
  "selectors": [
    {
      "user": "large-customer-sa",
      "group": "global.large_customer_exports"
    },
    {
      "user": ".*-service-account",
      "group": "global.small_tenants"
    },
    {
      "user": "data-team",
      "group": "global.internal_admin"
    }
  ]
}
```

### What each limit does

| Property | What it controls |
|---|---|
| `softMemoryLimit: "30%"` | When this group's queries exceed 30% cluster memory, new queries queue instead of running |
| `hardConcurrencyLimit: 2` | Maximum 2 queries from this group can run simultaneously |
| `softCpuLimit: "4h"` | Max CPU-hours this group can consume in the `cpuQuotaPeriod` window |
| `maxQueued: 20` | Max queries waiting in the queue; further submissions are rejected |
| `schedulingPolicy: "weighted_fair"` | Distributes slots fairly across sub-groups when they compete |

With this config, the large customer's export is capped at 2 concurrent queries and 30% cluster memory. Their export still completes — it just cannot monopolize the cluster. Small tenant dashboard queries land in `global.small_tenants` with their own 50 concurrent slots and never compete with the export queue.

### Three critical configuration details

**1. The `user` field matches the JWT principal name**, not a Trino role name. Check what principal the large customer's service account presents in JWT (`sub` claim) and match it exactly.

**2. Both files must exist and be correctly named.** A common mistake is adding the resource-groups lines to `etc/config.properties` instead of creating a separate `etc/resource-groups.properties` file. If you put them in config.properties, Trino boots cleanly with no error, the JSON sits on disk, but the limits are silently never applied.

**3. Use the exact property names from the Trino docs.** Common wrong names engineers try:

| Wrong name | Correct name |
|---|---|
| `maxRunning` | `hardConcurrencyLimit` |
| `maxMemoryPercent` | `softMemoryLimit` |
| `queues` | `maxQueued` |
| `cpuLimit` | `softCpuLimit` / `hardCpuLimit` |

### Deploying the config

Once both files are on the coordinator (via ConfigMap, GitOps sync, or manual copy), restart the coordinator for the limits to take effect:

```bash
kubectl rollout restart deployment/trino-coordinator -n trino
kubectl rollout status deployment/trino-coordinator -n trino
```

The coordinator restart kills all currently-running queries. Before restarting, you can terminate the offending export immediately:

```sql
-- Find the query ID
SELECT query_id, user, state, elapsed_time
FROM system.runtime.queries
WHERE user = 'large-customer-sa'
ORDER BY created DESC
LIMIT 5;

-- Kill it
CALL system.runtime.kill_query(
  query_id => '<query_id>',
  message  => 'Throttling per customer limits'
);
```

Then restart the coordinator to apply resource groups for all future queries.

### Verifying it works

After the restart, confirm the large customer's queries land in the right group:

```sql
SELECT query_id, user, state, resource_group_id
FROM system.runtime.queries
WHERE user = 'large-customer-sa'
ORDER BY created DESC
LIMIT 5;
```

The `resource_group_id` should show `['global', 'large_customer_exports']`. If it shows `['global']` instead, the selector regex did not match — check the actual JWT principal name the user is presenting.

### Optional: storage isolation

Resource groups fix the compute side (CPU/memory starvation). If the large customer's queries are also causing Iceberg manifest-list bloat or compaction contention on the shared table, the longer-term fix is migrating them to a dedicated Iceberg table. But resource groups alone will solve your immediate problem of one customer's export killing everyone else's queries.
