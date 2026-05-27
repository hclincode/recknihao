# Iter96 Q1 — Answer

**Question**: We are running Trino against our Iceberg tables for the analytics dashboard, and we have maybe 30 tenants hitting it at any given time. Lately some of our bigger customers are running very heavy reports — like a "usage over the last 12 months by day" export — and I suspect those queries are starving out the smaller tenants who just want a quick number on their dashboard. Is there a way in Trino to actually see which tenant's query is eating up the most resources right now, and can I do anything about it once I identify them, like canceling a runaway query or putting some kind of cap on how much compute a single tenant can use?

---

## Answer

## Step 1: Identify which tenant is eating resources

Trino exposes a system table called `system.runtime.queries` — a live query monitor showing everything running on your cluster. Query it as an admin:

```sql
SELECT
  query_id,
  "user" AS tenant_principal,
  state,
  query,
  resource_group_id,
  queued_time_ms
FROM system.runtime.queries
WHERE state IN ('RUNNING', 'QUEUED')
ORDER BY started DESC;
```

**Key columns:**
- `"user"` — the tenant principal (JWT subject). Must be quoted because `user` is a reserved word.
- `state` — `RUNNING` (actively consuming resources) or `QUEUED` (waiting because the cluster is saturated)
- `queued_time_ms` — how long this query waited before starting. High values signal resource contention.
- `resource_group_id` — which resource group bucket Trino assigned this query to
- `query` — the actual SQL, so you can see if it's really that 12-month export

If you see multiple `RUNNING` queries from the same tenant while other tenants' queries are in `QUEUED` state, that tenant is consuming more than their fair share.

**Real columns in system.runtime.queries** (Trino 467): query_id, state, user, source, query, resource_group_id, queued_time_ms, analysis_time_ms, planning_time_ms, created, started, last_heartbeat, end, error_type, error_code. There is no `bytes_scanned` or `statistics` column.

## Step 2: Kill a runaway query immediately

If a query has been running for hours and needs to stop:

```sql
CALL system.runtime.kill_query(
  query_id => '20260524_134522_00123_abcde',
  message  => 'Throttling runaway query — see incident #XYZ'
);
```

Get the `query_id` from the query above. This terminates the query immediately and releases its memory/CPU back to the cluster. Use this as first response during an active incident — it gives instant relief while you plan the longer-term fix.

## Step 3: Set up per-tenant resource limits

The durable fix is resource groups — per-tenant reservation buckets with limits on memory and concurrent queries. Create `etc/resource-groups.json` on your Trino coordinator:

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
          "name": "tenant_standard",
          "softMemoryLimit": "15%",
          "hardConcurrencyLimit": 5,
          "maxQueued": 50
        },
        {
          "name": "tenant_enterprise",
          "softMemoryLimit": "30%",
          "hardConcurrencyLimit": 8,
          "maxQueued": 100
        }
      ]
    }
  ],
  "selectors": [
    {
      "user": "acme-service-account",
      "group": "global.tenant_enterprise"
    },
    {
      "user": ".*",
      "group": "global.tenant_standard"
    }
  ]
}
```

What each limit does:

- **`softMemoryLimit`**: when a tenant's queries exceed this memory share, new queries from that tenant queue instead of running. Prevents one tenant from starving others.
- **`hardConcurrencyLimit`**: maximum simultaneous queries from this tenant. Once at 5, the 6th query waits.
- **`maxQueued`**: how many queries can wait. Once full, new queries are rejected with `QUERY_QUEUE_FULL`.
- **`selectors`**: matches JWT principal name (regex) to a resource group. The `"user"` field is a Java regex.

**Critical**: resource group config changes require a **coordinator restart** to take effect — they do not hot-reload. Only new queries submitted after the restart use the new limits.

## Step 4: Verify selectors are matching

After restart, check that queries land in the right group:

```sql
SELECT "user", resource_group_id, COUNT(*) AS query_count
FROM system.runtime.queries
WHERE state IN ('RUNNING', 'QUEUED')
GROUP BY "user", resource_group_id;
```

If a tenant is landing in `global` instead of `global.tenant_enterprise`, the selector regex didn't match — likely because the JWT principal name doesn't exactly match what you wrote. Cross-check the principal name from your auth service.

## Step 5: For persistent heavy export queries

The "12-month usage by day" export is inherently expensive. Beyond resource groups:

1. **Pre-computed rollups**: build a nightly table with one row per tenant per day. The dashboard reads 365 rows instead of scanning millions of events.
2. **Async exports**: submit the export as a background Trino job via the REST API, poll for completion, and serve results from MinIO rather than streaming synchronously.
3. **Separate compute cluster**: a dedicated Trino cluster for large exports pointing at the same Iceberg tables in MinIO — small-dashboard queries hit the main cluster, heavy reports hit the dedicated one.

## Security note

Make sure your access control denies tenant service accounts from querying the `system` catalog. Otherwise tenants can query `system.runtime.queries` and see every other tenant's SQL — a data leak. Specific deny rules live in your external OPA governance document.
