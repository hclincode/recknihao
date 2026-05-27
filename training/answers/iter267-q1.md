# Iter267 Q1 — Routing Dashboards vs Bulk Exports to Separate Query Limits: Trino Resource Groups

## Answer

Yes, Trino can absolutely route different types of queries to separate pools with independent limits. The feature is called **resource groups**, and it works exactly the way you described: dashboards go here, exports go there, internal ETL jobs go somewhere else.

### How Resource Groups Work

Think of resource groups as traffic cops for your queries. Each group has three main controls:

- **`hardConcurrencyLimit`**: Maximum number of queries that can run simultaneously in this group. If 10 dashboard queries are already running and an 11th arrives, it waits in the queue.
- **`maxQueued`**: Maximum number of queries that can wait in the queue. If 50 dashboard queries are already queued and a 51st arrives, it's **rejected immediately** with an error: `QUERY_REJECTED: Too many queued queries for group`.
- **`softMemoryLimit`**: If a group's queries collectively consume more than this percentage of cluster memory, new queries queue even if `hardConcurrencyLimit` hasn't been hit yet.

### How Trino Routes Queries to Groups: Selectors

Trino uses **selectors** to decide which group a query lands in. Selectors match on two things:
- **`user`**: The username running the query (supports regex)
- **`source`**: A label the client sets to identify itself (supports regex)

Selectors are evaluated **top to bottom**, and the first match wins. If no selector matches, the query is rejected.

The `source` label is the most flexible routing mechanism. Clients set it via:
- **JDBC URL**: `jdbc:trino://host:8080/catalog?source=dashboard-service`
- **Trino CLI**: `trino --source=export-job`
- **HTTP header**: `X-Trino-Source: etl-runner`

### Setting Up Resource Groups: The Two Files

You need exactly two files on the coordinator:

**File 1: `etc/resource-groups.properties`** — points Trino to the config file:
```properties
resource-groups.configuration-manager=file
resource-groups.config-file=etc/resource-groups.json
resource-groups.config-refresh-period=10s
```

The `config-refresh-period` means Trino hot-reloads the JSON file every 10 seconds — you can tune limits without restarting the coordinator.

**File 2: `etc/resource-groups.json`** — the actual group definitions:
```json
{
  "rootGroups": [{
    "name": "federation",
    "hardConcurrencyLimit": 100,
    "maxQueued": 200,
    "softMemoryLimit": "80%",
    "schedulingPolicy": "weighted",
    "subGroups": [
      {
        "name": "dashboards",
        "hardConcurrencyLimit": 10,
        "maxQueued": 50,
        "softMemoryLimit": "20%",
        "schedulingWeight": 10
      },
      {
        "name": "exports",
        "hardConcurrencyLimit": 2,
        "maxQueued": 20,
        "softMemoryLimit": "30%",
        "schedulingWeight": 1
      },
      {
        "name": "etl",
        "hardConcurrencyLimit": 4,
        "maxQueued": 30,
        "softMemoryLimit": "20%",
        "schedulingWeight": 2
      }
    ]
  }],
  "selectors": [
    { "source": "dashboard-.*", "group": "federation.dashboards" },
    { "source": "export-.*", "group": "federation.exports" },
    { "source": "etl-.*", "group": "federation.etl" },
    { "group": "federation" }
  ]
}
```

This configuration:
- Dashboards: up to 10 concurrent, 50 queued — high `schedulingWeight` (10) means they get priority when the cluster is contended
- Exports: up to 2 concurrent, 20 queued — `schedulingWeight` of 1 means they won't starve dashboards
- ETL: up to 4 concurrent, 30 queued — middle priority
- Final selector `{ "group": "federation" }` catches anything that doesn't match a source pattern and routes it to the root group (so it doesn't get rejected)

### What Happens When a Queue Fills Up

| Situation | What Trino Does |
|---|---|
| `hardConcurrencyLimit` reached, queue not full | Query waits in queue |
| `maxQueued` reached | Query immediately rejected with error |
| `softMemoryLimit` exceeded, even if concurrency limit not reached | Query queued until memory frees up |

So: your big export job lands in the `exports` group, hits `hardConcurrencyLimit = 2`, and the 3rd export query waits. Dashboard queries land in `dashboards` and can still run up to 10 concurrent regardless — they're completely isolated from the exports queue.

### How to Verify It's Working

Check which group a query landed in:

```sql
SELECT
  query_id,
  "user",
  source,
  resource_group_id,
  state,
  queued_time_ms
FROM system.runtime.queries
WHERE state IN ('RUNNING', 'QUEUED')
ORDER BY created DESC
LIMIT 20;
```

The `resource_group_id` column shows exactly which group each query was routed to. If you see queries in the wrong group, the selector pattern isn't matching — double-check the `source` your client is setting.

### Common Property Name Mistakes

Use these exact names in the JSON (Trino will reject invalid property names at startup):

| Correct | Wrong (will fail) |
|---|---|
| `maxQueued` | `maxQueuedQueries` |
| `hardConcurrencyLimit` | `maxRunning` |
| `softMemoryLimit` | `maxMemoryPercent` |
| `source` in selectors | `sourceRegex` |
| `user` in selectors | `userRegex` |

Also: do not put resource group properties in `config.properties` — they must go in `resource-groups.properties`. Putting them in the wrong file silently fails.
