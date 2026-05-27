# Iter266 Q1 — Queries Stuck Waiting Before They Run: Resource Groups and Connection Limits

## Answer

When a Trino query sits in a "waiting" state before it starts executing, you're hitting one of two independent resource limits. Understanding which one is the key to fixing it.

### The Two Layers: HTTP Connections vs Query Admission

Trino has two separate gatekeepers that can make queries queue up, and they operate at different layers:

1. **HTTP connection layer** (lower layer): The coordinator's HTTP server has a hard cap on how many simultaneous HTTP connections it will accept. If you hit this cap, new connections are rejected before Trino's query logic even sees them.

2. **Query admission layer** (higher layer): Once an HTTP connection lands on the coordinator, resource groups decide whether the query is admitted to run or queued. This is where you see queries stuck in `QUEUED` state while others run.

### How to Tell Which One You're Hitting

Check the Trino Web UI at `http://trino-coordinator:8080/ui/queries`:

- **If you see `QUEUED` state in the query list**: A query is waiting because another query is already running and the resource group has hit its concurrency limit. This is resource-group level queuing (Layer 2).

- **If you get immediate connection errors in your client logs** (like `Server returned HTTP response code: 503` or connection failures): The connection was rejected at the HTTP layer before the query even reached the queue (Layer 1).

You can also query the system catalog directly to see queued queries:

```sql
SELECT
  query_id,
  "user",
  resource_group_id,
  state,
  queued_time_ms,
  created
FROM system.runtime.queries
WHERE state = 'QUEUED'
ORDER BY queued_time_ms DESC;
```

### Fix 1: If Connections Are Being Rejected (Layer 1)

The issue is `http-server.max-connections` in the coordinator's `etc/config.properties`. This is a hard limit on simultaneous HTTP connections from all clients (your API service, Trino Web UI, CLI, dbt jobs, everything combined).

```properties
# etc/config.properties on the coordinator
http-server.max-connections=1500
```

Size it based on your total expected concurrent clients:
- If you have 50 API service replicas with connection pools of 20 connections each = 1000 connections
- Plus dbt Cloud jobs, CLI users, Web UI overhead
- Add 50% headroom for safety

After changing the value, restart the coordinator for it to take effect.

### Fix 2: If Queries Are in QUEUED State (Layer 2)

The issue is resource groups. Your query is waiting because the resource group's `hardConcurrencyLimit` has been reached — other queries are actively running and you've hit the cap.

Check the coordinator's `etc/resource-groups.json`:

```json
{
  "rootGroups": [{
    "name": "global",
    "hardConcurrencyLimit": 100,
    "maxQueuedQueries": 200,
    "subGroups": [
      {
        "name": "analytics",
        "hardConcurrencyLimit": 5,
        "maxQueuedQueries": 50,
        "softMemoryLimit": "20%"
      }
    ]
  }]
}
```

Key properties:
- **`hardConcurrencyLimit`**: Maximum number of queries that can run simultaneously in this group. Queries beyond this limit are queued.
- **`maxQueuedQueries`**: Maximum number of queries that can wait in the queue. Queries beyond this are rejected immediately with an error.
- **`softMemoryLimit`**: When the group exceeds this memory threshold, new queries are queued even if `hardConcurrencyLimit` is not reached.

**How to fix it:**

Option A: Increase `hardConcurrencyLimit` for the group your query lands in. Edit `etc/resource-groups.json` and increase the number, then restart the coordinator.

Option B: Stagger your queries. If you're running many dashboards or batch jobs simultaneously, space them out so fewer run at once.

Option C: Isolate heavy queries with separate subgroups so dashboard queries don't get starved:

```json
{
  "name": "dashboards",
  "hardConcurrencyLimit": 10,
  "softMemoryLimit": "20%",
  "maxQueuedQueries": 100
},
{
  "name": "exports",
  "hardConcurrencyLimit": 2,
  "softMemoryLimit": "30%",
  "maxQueuedQueries": 10
}
```

### The Critical Distinction (Do NOT Mix These Up)

Raising `hardConcurrencyLimit` does NOT fix connection rejection errors. The connection-layer limit is enforced before the query even gets to resource groups.

| Symptom | Problem | Fix |
|---|---|---|
| Connection errors in client logs (`503`, connection failures) | HTTP connection limit hit | Increase `http-server.max-connections` in `config.properties`, restart coordinator |
| Query shows `QUEUED` state in Trino UI | `hardConcurrencyLimit` hit | Increase `hardConcurrencyLimit` in `resource-groups.json`, or stagger queries |
| Query queued even with low concurrency | `softMemoryLimit` exceeded | Reduce memory usage per query, or increase `softMemoryLimit` |
| Query immediately rejected | `maxQueuedQueries` hit | Increase `maxQueuedQueries` or reduce incoming load |

### How to Prevent Future Queue Buildup

1. **Monitor the Trino UI regularly**: Check for `QUEUED` queries. If you routinely see more than 5 queries queued, your concurrency limits are too tight.

2. **Configure resource-groups.json before production traffic**: A typical pattern: allow 50–100 concurrent queries cluster-wide, then subdivide by workload type.

3. **Use separate resource groups for different workload types**: Heavy analytical jobs should never starve interactive dashboard queries.

4. **Check queue state with SQL**:

```sql
SELECT
  query_id,
  "user",
  resource_group_id,
  state,
  queued_time_ms,
  created
FROM system.runtime.queries
WHERE state = 'QUEUED'
ORDER BY queued_time_ms DESC;
```

Queries with high `queued_time_ms` relative to their total runtime signal that your resource groups are too restrictive.
