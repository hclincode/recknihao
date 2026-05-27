# Iter143 Q2 — Answer

**Question**: "We have maybe 30 enterprise customers on our platform and one of them runs these massive data exports every morning that seem to slow down the dashboard for everyone else. Is there a way in Trino to give different customers different resource limits, or put heavy queries in some kind of separate lane so they don't step on each other?"

---

## Trino Resource Groups for Multi-Tenant Query Isolation

Your problem is real and common: when one customer's massive export runs, it saturates your shared Trino cluster and every other customer's dashboard queries queue. **Trino resource groups** are exactly the tool for this — they let you enforce per-customer resource limits so one tenant cannot starve the others, and they can route different query types (exports vs. dashboards) into separate queues even for the same customer.

---

## What Resource Groups Do

A **resource group** is a named queue inside Trino with its own limits on:

- **`hardConcurrencyLimit`**: Maximum number of queries from this group running simultaneously. When hit, new queries queue instead of running.
- **`softMemoryLimit`**: A soft cap on total memory (e.g., `"20%"` of cluster or `"10GB"` absolute). When exceeded, new queries queue; existing queries continue.
- **`maxQueued`**: Maximum queries allowed to wait in the queue. Once hit, new submissions are rejected with a `QUERY_QUEUE_FULL` error instead of queuing.
- **`schedulingPolicy`**: `weighted_fair` (preferred for multi-tenant) — priorities queries from groups proportional to their `schedulingWeight`, preventing starvation.

---

## The Minimal Fix: Separate Export Lane

For your specific problem (one customer's morning export slowing dashboards), the minimal config is:

```json
{
  "rootGroups": [{
    "name": "global",
    "softMemoryLimit": "80%",
    "hardConcurrencyLimit": 50,
    "maxQueued": 500,
    "subGroups": [
      {"name": "exports", "softMemoryLimit": "30%", "hardConcurrencyLimit": 1, "maxQueued": 20},
      {"name": "default", "softMemoryLimit": "70%", "hardConcurrencyLimit": 49, "maxQueued": 480}
    ]
  }],
  "selectors": [
    {"user": ".*", "source": "export", "group": "global.exports"},
    {"user": ".*", "group": "global.default"}
  ]
}
```

Any query with `source: "export"` goes into the `exports` group: **max 1 concurrent query, 30% memory**. Everything else goes to `default` with 49 slots and 70% memory. One export cannot hog CPU because only 1 is allowed to run at a time; additional exports queue with a cap of 20. Meanwhile, dashboards have 49 slots and never compete with exports.

---

## Scaling Up: Separate Group Per Customer

For your 30-customer case, the cleanest approach is one subgroup per customer:

```json
{
  "rootGroups": [{
    "name": "global",
    "softMemoryLimit": "80%",
    "hardConcurrencyLimit": 100,
    "subGroups": [
      {"name": "acme",      "softMemoryLimit": "15%", "hardConcurrencyLimit": 5},
      {"name": "beta",      "softMemoryLimit": "15%", "hardConcurrencyLimit": 5},
      {"name": "acme_export", "softMemoryLimit": "25%", "hardConcurrencyLimit": 1}
    ]
  }],
  "selectors": [
    {"user": "acme-svc", "source": "export", "group": "global.acme_export"},
    {"user": "acme-svc", "group": "global.acme"},
    {"user": "beta-svc", "group": "global.beta"}
  ]
}
```

Acme's export (matching `source = "export"`) goes into `acme_export` (1 concurrent export, 25% memory). Acme's dashboards go into `acme` (5 slots, 15% memory). Every other customer lands in their own bounded group.

---

## Per-Query-Type Subgroups with Weighted Fair Scheduling

For finer control per customer, use nested subgroups with weighted scheduling:

```json
{
  "rootGroups": [{
    "name": "global",
    "softMemoryLimit": "80%",
    "hardConcurrencyLimit": 100,
    "schedulingPolicy": "weighted_fair",
    "subGroups": [{
      "name": "tenant_acme",
      "softMemoryLimit": "20%",
      "hardConcurrencyLimit": 5,
      "subGroups": [
        {"name": "dashboards", "softMemoryLimit": "10%", "hardConcurrencyLimit": 4, "schedulingWeight": 10},
        {"name": "exports",    "softMemoryLimit": "15%", "hardConcurrencyLimit": 1, "schedulingWeight": 1}
      ]
    }]
  }],
  "selectors": [
    {"user": "acme-svc", "source": ".*dashboard.*", "group": "global.tenant_acme.dashboards"},
    {"user": "acme-svc", "source": ".*export.*",    "group": "global.tenant_acme.exports"},
    {"user": "acme-svc", "group": "global.tenant_acme.dashboards"}
  ]
}
```

The `weighted_fair` scheduler on the parent means dashboards get ~10 slots for every 1 export slot when both are queued — so a long-running export does not block interactive dashboards.

---

## How Query Routing Works

Selectors match on the **JWT principal** (the username Trino extracted from the JWT `sub` claim) and optionally the `source` string the client supplied when opening the connection. Selectors are evaluated top-down; the **first match wins**.

If your auth service mints a JWT with `sub: "acme-service-account"`, configure the selector with `"user": "acme-service-account"`. The source string is typically set by your export tool (e.g., `source: "export"`) when opening the Trino JDBC connection.

---

## What Happens to Queued Queries

When a query hits `hardConcurrencyLimit` or `softMemoryLimit`:

1. **It queues** (enters the `QUEUED` state, visible in `system.runtime.queries`).
2. **It waits** until a slot frees up (another query finishes) or memory is released.
3. **If `maxQueued` is exceeded**, the query is **rejected at submission** with `QUERY_QUEUE_FULL` error — it does not queue, it fails immediately.

Queued queries can wait minutes or hours. The `maxQueued` cap prevents the queue from growing unbounded.

---

## Critical Setup Requirements

**Create two separate files on your Trino coordinator:**

`etc/resource-groups.properties` (new file):
```properties
resource-groups.configuration-manager=file
resource-groups.config-file=etc/resource-groups.json
```

This must be a **separate file** — do not merge it into `etc/config.properties`. If you put these properties in `config.properties`, Trino silently ignores them and the resource groups never load.

**Use the correct property names** in the JSON:
- `hardConcurrencyLimit` (NOT `maxRunning`)
- `softMemoryLimit` (NOT `maxMemoryPercent`)
- `maxQueued` (correct)
- `schedulingPolicy` (NOT `policy`)
- `schedulingWeight` (only used when parent has `"schedulingPolicy": "weighted_fair"`)

---

## Deploying: Coordinator Restart Required

Resource group config is **not hot-reloaded**. Editing the JSON requires a Trino coordinator restart:

```bash
kubectl rollout restart deployment/trino-coordinator -n trino
```

A restart **kills all in-flight queries**. Plan it for low-traffic periods.

For an active incident (one tenant is starving the cluster right now), kill the offending query immediately instead of waiting for a restart:

```sql
CALL system.runtime.kill_query(
  query_id => '20260526_040000_00123_abcde',
  message  => 'Exceeding resource limits — see incident #XXX'
);
```

This gives instant relief; then restart later to prevent recurrence.

---

## Monitoring Which Group Queries Land In

```sql
SELECT query_id, user, state, resource_group_id
FROM system.runtime.queries
WHERE state IN ('RUNNING', 'QUEUED')
ORDER BY created DESC;
```

The `resource_group_id` column shows the group path as an array (e.g., `ARRAY['global', 'tenant_acme', 'exports']`). If an export from `acme-svc` is landing in `ARRAY['global', 'default']` instead of the expected export group, the selector didn't match — check that the JWT principal name and the `source` string match your regex exactly.

---

## Production Recommendation for Your 30-Customer Case

Start with the **minimal fix** (separate exports group) to immediately stop the morning slowdown. Then add per-customer groups over the next week. Set a baseline per customer of `softMemoryLimit: "15%"` and `hardConcurrencyLimit: 5`. Identify "heavy" customers (the ones running big exports) and add dedicated export subgroups for them with `hardConcurrencyLimit: 1`.

**The key insight**: resource groups are not about fairness — they're about **isolation**. You're guaranteeing that no single customer can take the whole cluster, no matter how expensive their query is.
