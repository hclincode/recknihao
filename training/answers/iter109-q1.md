# Iter109 Q1 — Answer

**Question**: We have about 300 customers sharing the same Trino + Iceberg setup. One of our bigger customers runs a nightly report that reads two years of their event data — it consistently takes 20-30 minutes and we can see from Trino's query history that it's doing a massive scan. The problem is, during that window, other customers' dashboard queries slow to a crawl. How do I stop one heavy customer from degrading everyone else's experience? Is there something I can configure in Trino, or does this have to be solved at the data layout level, or both?

---

## Answer

You have a **noisy-neighbor problem** — one heavy customer is starving everyone else. The answer is **both configuration AND data layout**: Trino resource groups stop the heavy customer from hogging cluster resources, and Iceberg partitioning makes their queries faster and cheaper in the first place. Do both.

**Immediate relief** while deploying the fix: kill the heavy query now using `CALL system.runtime.kill_query(...)` to free cluster resources.

## Solution 1: Trino Resource Groups (prevents resource starvation)

Resource groups let you cap CPU, memory, and concurrent queries per tenant. When a heavy customer's report tries to use more than its allocated share, it queues instead of starving other tenants.

### The two-file setup

**File 1: `etc/resource-groups.properties`** (pointer file — exactly these two lines):

```properties
resource-groups.configuration-manager=file
resource-groups.config-file=etc/resource-groups.json
```

Without this file, the JSON is dead config — Trino never loads it.

**File 2: `etc/resource-groups.json`** (the actual limits):

```json
{
  "rootGroups": [
    {
      "name": "global",
      "softMemoryLimit": "80%",
      "hardConcurrencyLimit": 100,
      "maxQueued": 100,
      "subGroups": [
        {
          "name": "tenant_default",
          "softMemoryLimit": "20%",
          "hardConcurrencyLimit": 5,
          "maxQueued": 20,
          "schedulingWeight": 1
        },
        {
          "name": "tenant_heavy",
          "softMemoryLimit": "30%",
          "hardConcurrencyLimit": 3,
          "maxQueued": 30,
          "schedulingWeight": 1
        }
      ]
    }
  ],
  "selectors": [
    {
      "user": "heavy-customer-service-account",
      "group": "global.tenant_heavy"
    },
    {
      "group": "global.tenant_default"
    }
  ]
}
```

**What this does:**
- Heavy customer queries (principal `heavy-customer-service-account`) land in `global.tenant_heavy`: capped at 30% cluster memory, max 3 concurrent queries
- All other customers go into `global.tenant_default`: 20% memory, max 5 concurrent queries
- Queries exceeding their soft memory limit queue in `maxQueued` slots instead of killing other queries
- The `"user"` selector must match the JWT principal exactly — verify the exact principal string from your auth service

### Deploy and verify

Push the two files to your Trino coordinator pod (via ConfigMap in Kubernetes), restart:

```bash
kubectl rollout restart deployment/trino-coordinator -n trino
```

Verify queries land in the right group:

```sql
SELECT query_id, user, state, resource_group_id
FROM system.runtime.queries
WHERE state IN ('RUNNING', 'QUEUED')
ORDER BY created DESC;
```

`resource_group_id` should show `global.tenant_heavy` for the heavy customer. If it shows the root `global`, the selector didn't match — double-check the JWT principal name.

### Kill the current incident

```sql
-- Run as admin user; query_id from system.runtime.queries
CALL system.runtime.kill_query('20240525_123456_00001_aaaaa');
```

## Solution 2: Iceberg Partitioning (makes their queries faster)

Even with resource groups, a 2-year full-table scan is slow and wastes cluster resources. Fix the data layout so the heavy customer's queries only read their own files.

### The problem

If your table is partitioned by `day(event_ts)` alone, a query for one customer still reads every tenant's files for those dates — partition pruning only works on `event_ts`.

### The fix: add `tenant_id` to the partition key

```sql
CREATE TABLE analytics.events (
  event_id    BIGINT,
  tenant_id   VARCHAR,
  user_id     VARCHAR,
  event_type  VARCHAR,
  event_ts    TIMESTAMP
)
WITH (partitioning = ARRAY['tenant_id', 'day(event_ts)'])
```

Now `WHERE tenant_id = 'heavy_customer' AND event_ts >= DATE '2024-05-01'` only opens that customer's files for that date range. Iceberg hidden partitioning applies the pruning automatically — no application SQL changes needed.

### Migration path for existing tables

Iceberg supports partition evolution — new data uses the new spec, old data stays on the old spec. Rewrite old files during a maintenance window using Spark:

```python
spark.sql("""
  CALL iceberg.system.rewrite_data_files(
    table => 'analytics.events',
    options => map('min-file-size-bytes', '268435456')
  )
""")
```

## Why both matter

| | Resource groups alone | Partitioning alone |
|---|---|---|
| Heavy customer's query speed | Still slow (scans all files) | Fast (scans only their files) |
| Impact on other tenants | Protected (queued, not starved) | Not protected (concurrency uncapped) |
| Cluster resource waste | High (large scans) | Lower (pruned scans) |

**Both together**: the heavy customer's 2-year scan reads only their partition (fast), and even if they run many in parallel, resource groups cap their concurrency and memory — protecting every other tenant.

## Common mistakes to avoid

1. **Wrong property names**: Use `softMemoryLimit`, `hardConcurrencyLimit`, `maxQueued` — not `maxMemoryPercent` or `maxCpuPercent`. Trino silently ignores unrecognized names.
2. **Missing `etc/resource-groups.properties`**: The JSON alone is inert. The pointer file is required.
3. **Selector doesn't match JWT principal**: If your JWT principal is `acme-svc@company` but the selector says `"user": "acme-svc"`, it won't match. Check exact principal strings in your auth service.
