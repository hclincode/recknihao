# Iter100 Q1 — Answer

**Question**: We're onboarding a new enterprise customer whose data volume is about 10x larger than any of our existing tenants — they generate around 50 million events per day compared to our typical 5 million. Everything is stored in a shared Iceberg table partitioned by tenant ID and date. I'm worried that queries for other tenants will slow down whenever this big tenant's partitions are getting written to or compacted. Is there something I can do at the Trino or Iceberg level to prevent one tenant's workload from hogging resources and slowing down everyone else, or do we need to rethink the whole table structure?

---

## Answer

Your concern is valid. A 10x outlier in a shared table creates a "noisy neighbor" problem — one tenant can monopolize your Trino cluster's CPU, memory, and disk I/O, leaving everyone else's queries queued. Good news: **you do not need to rethink the table structure.** You have two proven tools that work together at the Trino and Iceberg layers to prevent this, plus an optional escalation path if you need complete isolation.

### The core problem: shared resources, unequal workloads

When the enterprise tenant writes 50 million events in a daily batch, Spark creates new Parquet files and triggers Iceberg compaction — merging small files into larger ones. Compaction is CPU-intensive, pulling cluster resources. Meanwhile, other tenants' dashboard queries are running. With no isolation, the big tenant's compaction can saturate your cluster, leaving smaller tenants' queries waiting indefinitely. Logically the data is separated (by the `tenant_id` column), but cluster resources are fully shared.

### Solution 1: Trino resource groups (immediate, most practical fix)

Trino offers **resource groups** — a built-in scheduler that caps how much memory, CPU, and concurrent queries a single tenant can use. Think of it like assigning highway lanes: the big tenant gets one lane, the rest share another, and they never interfere.

**Step 1: Create `etc/resource-groups.json` on your Trino coordinator.**

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
          "name": "enterprise_tenant",
          "softMemoryLimit": "40%",
          "hardConcurrencyLimit": 10,
          "maxQueued": 100
        },
        {
          "name": "standard_tenants",
          "softMemoryLimit": "40%",
          "hardConcurrencyLimit": 20,
          "maxQueued": 200
        }
      ]
    }
  ],
  "selectors": [
    {
      "user": "enterprise-service-account",
      "group": "global.enterprise_tenant"
    },
    {
      "user": ".*-service-account",
      "group": "global.standard_tenants"
    }
  ]
}
```

What this does:
- Enterprise tenant: max 40% cluster memory, max 10 concurrent queries.
- Other tenants: max 40% cluster memory, max 20 concurrent queries.
- Remaining 20%: headroom for internal operations and system queries.

When the enterprise tenant hits its limits, new queries queue instead of starving the cluster.

**Step 2: Register the file with Trino.** Add these two lines to `etc/config.properties` on the coordinator:

```properties
resource-groups.configuration-manager=file
resource-groups.config-file=etc/resource-groups.json
```

**Step 3: Restart the Trino coordinator** so it reads the new configuration.

**Critical production details:**

- The `"user"` field matches the **JWT principal** (service account name), not the Trino role. Your production stack uses JWT, so match the exact service account: `"user": "enterprise-service-account"`, not `"user": "enterprise_role"`. Mismatches are silent failures — the group never applies.
- Use exact Trino property names. Common mistakes: `maxRunning` doesn't exist (it's `hardConcurrencyLimit`), `maxMemoryPercent` doesn't exist (it's `softMemoryLimit`). Wrong names silently fail — the file loads, the limit never applies.

### Solution 2: Iceberg nightly compaction (prevent small-file accumulation)

Your current partitioning (`tenant_id, date`) is good and is the standard multi-tenant layout. However, if the enterprise tenant's daily writes generate many small Parquet files (from frequent micro-batches), those files accumulate. Subsequent compaction becomes expensive because Trino spends minutes just opening thousands of tiny files before reading any data.

Schedule a nightly **compaction job** in Spark, running after ingestion finishes (e.g., 4 AM if ingestion ends at 2 AM):

```sql
-- Spark SQL only, not Trino
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.events',
  options => map(
    'target-file-size-bytes', '268435456',
    'min-input-files',        '5'
  )
);
```

This merges small files into healthy 256 MB chunks. When the enterprise tenant's next queries hit the table, Trino doesn't waste time opening thousands of tiny files (each file open costs 10-50 ms; 10,000 tiny files = catastrophic overhead).

Follow with weekly `expire_snapshots` to reclaim MinIO storage:

```sql
-- Spark SQL only
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.events',
  older_than  => current_timestamp - interval '7' day,
  retain_last => 10
);
```

### Solution 3: Escalation options (only if resource groups aren't sufficient)

If resource groups still aren't controlling the noisy neighbor:

**Option A: Dedicated table for the big tenant**
Move the enterprise tenant into their own Iceberg table (`analytics.enterprise_events`) while keeping the shared table for everyone else. Trade-off: one extra schema to maintain, but the enterprise tenant's writes and compactions no longer interfere with shared-tenant queries.

**Option B: Dedicated Trino cluster for the enterprise tier**
Run two Trino clusters reading the same MinIO storage. Enterprise queries hit their own cluster; standard tenants share another. No duplicate storage (both read the same Iceberg tables), but compute is fully isolated. More ops overhead, but bulletproof isolation.

Start with resource groups. Only escalate to table/cluster isolation if measurements show it's insufficient.

### How to verify it's working

After setup, run this diagnostic query:

```sql
SELECT query_id, user, state, resource_group_id
FROM system.runtime.queries
WHERE state IN ('RUNNING', 'QUEUED')
ORDER BY created DESC
LIMIT 10;
```

Queries from the enterprise tenant should show `resource_group_id = 'global.enterprise_tenant'`. If they show `global`, the selector regex didn't match — check the JWT principal name.

Then trigger heavy queries from both enterprise and standard tenants simultaneously and watch the Trino UI — the enterprise tenant respects its 40% memory cap and 10-concurrent-query limit, while standard tenants proceed in parallel.

### Summary

You do not need to rethink the table structure. The shared table with `tenant_id` and date partitioning is the standard multi-tenant design and is correct. Apply these three layers:

1. **Trino resource groups** to cap the enterprise tenant's resource consumption (immediate, lowest-effort fix).
2. **Nightly Iceberg compaction** to keep file counts healthy and prevent file-open overhead.
3. **Optional table/cluster isolation** if measurements show resource groups alone are insufficient.

This combination costs minimal engineering effort — mostly JSON configuration and a scheduled Spark job — and provides comprehensive noisy-neighbor protection.
