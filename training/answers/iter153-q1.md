# Iter 153 Q1 — Trino Memory Limit and Spill-to-Disk for Large Joins

## Answer

Your error (`Query exceeded per-node memory limit`) is documented in the production runbook. Let me explain what it means and what your options are.

### What the error means

Trino enforces two memory limits:

| Error | Root cause | Config property |
|---|---|---|
| `EXCEEDED_LOCAL_MEMORY_LIMIT` | One worker node hit its per-query memory cap | `query.max-memory-per-node` |
| `EXCEEDED_DISTRIBUTED_MEMORY_LIMIT` | The query's total memory across all workers hit the cluster cap | `query.max-memory` |

Your production config has:
- `query.max-memory-per-node=8GB` (per worker)
- `query.max-memory=200GB` (cluster total)

A join between 300 million event rows and a dimension table will try to build a hash table in memory on each worker. If the events table grew and the hash table now exceeds `query.max-memory-per-node`, you hit the per-node error.

### What to do — in order of preference

**Option 1: Add a partition filter to narrow the scan (fastest fix)**

The single most effective change is making sure Trino only reads the data it needs before the join. If `event_date` is a partition column on your events table:

```sql
SELECT
    d.tenant_id,
    COUNT(DISTINCT e.user_id) AS unique_users,
    COUNT(*) AS event_count
FROM iceberg.analytics.events AS e
JOIN iceberg.dimensions.customers AS d ON e.tenant_id = d.tenant_id
WHERE e.event_date >= CURRENT_DATE - INTERVAL '90' DAY  -- partition pruning
  AND d.status = 'active'
GROUP BY d.tenant_id;
```

If the WHERE clause already has this filter and you're still OOMing, the 90-day window is just too large for the join to fit in memory at current cluster size.

**Option 2: Pre-aggregate before joining**

Instead of joining raw events (300M rows) to the customer dimension, compute the funnel metrics for each tenant first:

```sql
WITH tenant_metrics AS (
    SELECT
        tenant_id,
        COUNT(DISTINCT user_id) AS unique_users,
        COUNT(*) AS event_count
    FROM iceberg.analytics.events
    WHERE event_date >= CURRENT_DATE - INTERVAL '90' DAY
    GROUP BY tenant_id
)
SELECT
    d.tenant_name,
    d.plan_tier,
    tm.unique_users,
    tm.event_count
FROM tenant_metrics AS tm
JOIN iceberg.dimensions.customers AS d ON tm.tenant_id = d.tenant_id;
```

The first step aggregates 300M rows down to one row per tenant before the join. The join then operates on a much smaller dataset.

**Option 3: Increase the memory limit (if cluster has capacity)**

If the query is legitimately large and your workers have unused RAM, raise the per-node limit in `etc/config.properties` on all worker nodes:

```properties
query.max-memory-per-node=16GB
```

Restart workers after changing this. This only helps if workers actually have the additional RAM available — check worker node utilization before increasing.

**Option 4: Denormalize the data model**

For a funnel report that runs repeatedly, pre-join the dimension data into a wide fact table during nightly ingestion. This eliminates the join at query time entirely. See resources on schema design for analytics (`08-schema-design-for-analytics.md`).

### On spill-to-disk

The current resources do not document Trino's spill-to-disk configuration for this on-prem stack. The general approach documented here prioritizes fixing queries and scaling workers rather than relying on spill-to-disk (which is slower than in-memory execution and is a last resort).

### Diagnosis step

Run `EXPLAIN ANALYZE` on the failing query to confirm where the memory is being consumed:

```sql
EXPLAIN ANALYZE
SELECT ... -- your join query
```

Look for the operator with the highest `Physical Input:` bytes — that is usually where the memory pressure originates. If it's the join, the pre-aggregation approach in Option 2 is the right fix.

### Summary

| Option | When to use | Complexity |
|---|---|---|
| Add partition filter to WHERE | Query is scanning too much data | Low |
| Pre-aggregate before join | Join with large fact table | Medium |
| Increase query.max-memory-per-node | Workers have unused RAM | Low (config change) |
| Denormalize to wide fact table | Query runs frequently | High (data model change) |
