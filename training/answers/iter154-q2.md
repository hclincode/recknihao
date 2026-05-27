# Iter 154 Q2 — Trino Resource Groups for Query Prioritization

## Answer

## Trino Resource Groups for Query Prioritization

Yes, Trino has exactly the tool you need: **resource groups**. They allow you to set concurrency limits, memory caps, and scheduling policies that separate interactive dashboard queries from scheduled batch workloads — ensuring dashboards get priority when both are running simultaneously.

### The Root Problem

When 20-30 queries run at once, they compete for the same fixed CPU and memory budget on your worker nodes. Each additional query gets a smaller slice, so all of them slow down. Resource groups work by admitting queries **selectively** — interactive queries from active dashboards cut to the front; scheduled reports queue behind them and get lower concurrency limits.

### How Resource Groups Work Under the Hood

Resource groups operate at the **query admission layer** — before a query even touches a worker. Here's the flow:

1. **Query arrives** at the Trino coordinator with a user identity (from your JWT authenticator).
2. **Selector matches** the query to a group based on user, source (BI tool name), or other metadata.
3. **Group limits are checked**: Does the group have room (available concurrency slots, memory budget)? If yes, the query runs. If no, it queues.
4. **Queries in a queue are scheduled** fairly or weighted according to the group's `schedulingPolicy`.

The key insight: **a queued query consumes no resources**. It waits harmlessly until a slot frees up. Dashboard queries with higher concurrency limits get their slots faster.

### Configuration: Two Files Required

Resource groups require **two separate files** on your Trino coordinator. This is the most common setup mistake — engineers write only one file and wonder why nothing happens.

**File 1: `etc/resource-groups.properties`** (tells Trino where to find the actual config)

```properties
resource-groups.configuration-manager=file
resource-groups.config-file=etc/resource-groups.json
```

**File 2: `etc/resource-groups.json`** (the actual group definitions)

```json
{
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
          "softMemoryLimit": "60%",
          "hardConcurrencyLimit": 20,
          "maxQueued": 100,
          "schedulingWeight": 10
        },
        {
          "name": "scheduled_reports",
          "softMemoryLimit": "40%",
          "hardConcurrencyLimit": 5,
          "maxQueued": 50,
          "schedulingWeight": 1
        }
      ]
    }
  ],
  "selectors": [
    {
      "source": ".*dashboard.*",
      "group": "global.dashboards"
    },
    {
      "source": ".*scheduled.*|.*export.*|.*batch.*",
      "group": "global.scheduled_reports"
    }
  ]
}
```

### What Each Limit Does

| Setting | What it controls | Your case |
|---------|------------------|-----------|
| `hardConcurrencyLimit` | Max queries **running simultaneously** in this group | Dashboard group: 20 |
| `softMemoryLimit` | Soft cap on total memory across all queries in the group | Dashboard: 60% of cluster memory |
| `maxQueued` | Max queries that can wait in the queue | Dashboards: 100 waiting |
| `schedulingWeight` | **Relative priority** when multiple subgroups compete for slots | Dashboards weight=10, reports weight=1 → ~10:1 admission ratio |

The critical field for your use case is **`schedulingWeight`**: with dashboards at 10 and reports at 1, Trino admits roughly **10 dashboard queries for every 1 scheduled report** when both queues have pending work. Reports still run, but dashboards get priority.

### How It Actually Solves Your Problem

Before resource groups:
- 30 queries all competing equally → each takes 3–4 minutes instead of 10 seconds.

After resource groups:
- Dashboard queries land in `global.dashboards` with `hardConcurrencyLimit: 20` → 20 dashboards run in parallel at near-normal speed.
- Scheduled reports land in `global.scheduled_reports` with `hardConcurrencyLimit: 5` → they queue behind dashboards and run 5 at a time.
- When dashboards finish, reports dequeue and start.
- The `schedulingPolicy: "weighted_fair"` on the parent ensures dashboards keep getting 10x the new slots while reports slowly drain.

### Critical Configuration Gotchas

1. **Property names are exact.** Use `hardConcurrencyLimit`, not `maxRunning`. Use `softMemoryLimit`, not `maxMemoryPercent`. If you misspell a property, Trino silently ignores it — no error, just dead config.

2. **`schedulingWeight` is inert unless the parent has `schedulingPolicy`.** A common bug: you set `schedulingWeight: 10` on dashboards but forget `"schedulingPolicy": "weighted_fair"` on the parent group. The weights silently do nothing — the parent defaults to `"fair"` (round-robin), and weights are ignored entirely. **Always set the scheduling policy on the parent group if child subgroups have non-uniform weights.**

3. **File-based resource groups require coordinator restart to take effect.** Editing the JSON and pushing it does nothing. You must restart the coordinator:
   ```bash
   kubectl rollout restart deployment/trino-coordinator -n trino
   ```
   This kills all in-flight queries, so only do it during low-traffic windows.

4. **Verify both files exist on the coordinator:**
   ```bash
   ls etc/resource-groups.properties   # Must exist
   ls etc/resource-groups.json          # Must exist
   ```
   If either is missing, resource groups don't activate.

### Immediate Incident Response

If a scheduled report is currently starving the whole cluster, **don't wait for a restart** — kill the query directly:

```sql
CALL system.runtime.kill_query(
  query_id => '20260525_143012_00042_abcde',
  message  => 'Throttling long-running report, see incident #123'
);
```

Then deploy the resource-groups.json change and restart the coordinator.

### Monitoring Your Configuration

To verify that queries are landing in the groups you expect:

```sql
SELECT query_id, user, state, resource_group_id
FROM system.runtime.queries
WHERE state IN ('RUNNING', 'QUEUED')
ORDER BY created DESC;
```

The `resource_group_id` column shows the group path each query landed in (e.g., `ARRAY['global', 'dashboards']`). If dashboard queries are showing `ARRAY['global']` instead of `ARRAY['global', 'dashboards']`, your selector didn't match — check that the `source` regex matches what your BI tool actually reports.

### For Hot-Reload (Without Restarts)

If you want to tune resource-group limits frequently without restarting the coordinator, Trino supports a **database-backed resource group manager** that re-reads config every 1 second. This requires a small Postgres/MySQL instance but eliminates restart windows. See `resource-groups.configuration-manager=db` in the production resources for the setup.
