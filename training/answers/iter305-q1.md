# Answer to Q1: Trino Resource Groups — Stopping Ingestion from Starving Dashboards (Iter 305)

## What Trino Resource Groups Actually Do

Resource groups are **not just a queue** — they're a constraint layer that simultaneously controls **concurrency** (how many queries run at once), **memory allocation** (how much RAM each workload can consume), and **query admission** (preventing new queries from starting when you're already saturated).

When your ingestion jobs hammer the cluster, dashboards timeout because both workloads compete for the same finite pool of worker slots and memory. Resource groups let you **carve out guaranteed capacity for dashboards** — so even when ingestion is at full throttle, dashboard queries always get served quickly because they're assigned their own separate concurrency and memory budget.

## How Resource Groups Control Resources

Resource groups expose three levers:

1. **`hardConcurrencyLimit`** — Maximum number of queries that can run **simultaneously** in that group. When this limit is hit, the next query waits in a queue rather than starting immediately.

2. **`softMemoryLimit`** — Memory budget for the group, expressed as a percentage of total cluster memory (e.g., `"40%"`) or as absolute bytes (e.g., `"50GB"`). When a group exceeds this, new queries are queued until running queries finish and free memory. This is a **soft limit** — a query already running is not killed, but new ones wait.

3. **`maxQueued`** — Maximum number of queries allowed to wait in the queue. Once this is hit, additional submissions are rejected immediately with a `QUERY_QUEUE_FULL` error.

Key insight: **`hardConcurrencyLimit` controls how many queries run, `softMemoryLimit` controls how much memory, and together they prevent one workload from starving another.**

## How Query Routing Works: Selectors

You define groups in JSON, then use **selectors** to route queries to the right group based on:

- **`user`** — authenticated identity of the caller
- **`source`** — client source string (set via `X-Trino-Source` HTTP header or `--source` CLI flag)
- **`queryType`** — (optional) `SELECT`, `INSERT`, `SYSTEM_INFORMATION`, etc.

Selectors are evaluated **top-to-bottom, first-match-wins**. Your dashboard BI tool sets `source=dashboard`, your Spark ingestion sets `source=spark-ingestion`, and each lands in its own resource group.

## Production-Ready Configuration

**Step 1: Create `etc/resource-groups.properties`** (registers the JSON file with Trino)

```properties
# /etc/trino/resource-groups.properties on the coordinator
resource-groups.configuration-manager=file
resource-groups.config-file=etc/resource-groups.json
```

**Step 2: Create `etc/resource-groups.json`**

```json
{
  "rootGroups": [
    {
      "name": "global",
      "softMemoryLimit": "90%",
      "hardConcurrencyLimit": 50,
      "maxQueued": 500,
      "subGroups": [
        {
          "name": "dashboards",
          "softMemoryLimit": "40%",
          "hardConcurrencyLimit": 20,
          "maxQueued": 100,
          "schedulingWeight": 10
        },
        {
          "name": "ingestion",
          "softMemoryLimit": "50%",
          "hardConcurrencyLimit": 15,
          "maxQueued": 50,
          "schedulingWeight": 5
        }
      ],
      "schedulingPolicy": "weighted_fair"
    }
  ],
  "selectors": [
    {
      "source": "dashboard",
      "group": "global.dashboards"
    },
    {
      "source": "spark-ingestion",
      "group": "global.ingestion"
    },
    {
      "group": "global"
    }
  ]
}
```

**What this does:**
- **Dashboards** get 40% of cluster memory, up to 20 concurrent queries, queue depth 100
- **Ingestion** gets 50% of cluster memory, up to 15 concurrent queries, queue depth 50
- **`schedulingWeight`**: when both groups are under load, dashboards get 2x scheduling priority (weight 10 vs 5)
- `schedulingPolicy: weighted_fair` ensures neither group starves the other
- Everything else falls through to the root `global` group (safety valve at 50 concurrent, 90% memory)

**Step 3: Set the source string in your clients**

For dashboard BI tools (Metabase, Superset, etc.) — set `X-Trino-Source: dashboard` in the connection config, or via JDBC URL parameter `?source=dashboard`.

For Spark ingestion jobs — set the source in your connector configuration so it appears as `source=spark-ingestion` in Trino's query registry.

**Step 4: Restart the Trino coordinator**

```bash
kubectl rollout restart deployment/trino-coordinator -n trino
kubectl rollout status deployment/trino-coordinator -n trino
```

New limits take effect for queries submitted after restart.

## Verifying It Works

After restart, check the Trino Web UI (`http://trino-coordinator:8080/ui/queries`) and look at the `resource_group_id` column — you should see dashboard queries in `global.dashboards` and ingestion in `global.ingestion`.

Query the runtime system view:

```sql
SELECT
  query_id,
  "user",
  source,
  state,
  resource_group_id
FROM system.runtime.queries
WHERE state IN ('RUNNING', 'QUEUED')
ORDER BY created DESC;
```

When ingestion is at 15 concurrent queries (the limit), ingestion query #16 will show `QUEUED` state while dashboard queries start within seconds in their separate pool.

## Common Mistakes to Avoid

1. **Forgetting `etc/resource-groups.properties`** — The JSON file alone is inert. Trino will not discover it automatically. This is the most common mistake.

2. **Wrong property names** — Use exactly:
   - `hardConcurrencyLimit` (not `maxRunning` or `concurrencyLimit`)
   - `softMemoryLimit` (not `memoryLimit` or `maxMemoryPercent`)

3. **Confusing `softMemoryLimit` with per-query memory** — `softMemoryLimit` queues new queries when the group exceeds its budget. It does not kill running queries or enforce per-query caps. For per-query memory limits, use `query.max-memory-per-node` in `etc/config.properties`.

4. **Not setting the source string in clients** — If clients don't set `source`, queries fall through to the root group and resource group isolation doesn't work.
