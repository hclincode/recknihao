# Iter278 Q2 — Resource Groups to Limit Concurrent Postgres Queries

## Answer

Yes, Trino has a native mechanism to queue and cap concurrent queries: **resource groups**. Here's what you need to know.

### 1. OSS Trino 467 Has No Per-Catalog Connection Pool

First, the clarification: OSS Trino 467 does NOT have `connection-pool.enabled`, `connection-pool.max-size`, or similar per-catalog properties for the PostgreSQL connector. Those are Starburst Enterprise-only features. If you add them to your catalog properties file, Trino silently ignores them.

### 2. Resource Groups: The Trino-Side Lever

**Resource groups** cap how many queries run concurrently. Fewer concurrent queries = fewer simultaneous Postgres connections. This is not a connection pool, but it is the correct Trino-side mechanism.

The two key properties:
- **`hardConcurrencyLimit: N`** — at most N queries run concurrently. Queries beyond this are queued.
- **`maxQueued: M`** — if N are running and M are waiting, the next query is rejected with "Too many queued queries."

Example: `hardConcurrencyLimit: 2`, `maxQueued: 50` → two queries run, up to 50 wait in queue, the 53rd is rejected.

### 3. How Queuing Works

When a query arrives at the coordinator:
1. The coordinator checks `selectors` in `resource-groups.json` to determine which group the query belongs to.
2. If the group's `hardConcurrencyLimit` is full, the query enters the queue.
3. Postgres never sees queued queries — it only sees queries that have started running on Trino workers.
4. When a running query finishes, Trino dequeues the next waiting query.

Result: your Postgres replica sees at most 2-3 concurrent connections instead of 5-6 simultaneous spikes.

### 4. CRITICAL: The Source Selector Caveat

The most common failure mode: **if clients don't set `X-Trino-Source`, the selector silently doesn't match and queries bypass the resource group entirely.**

If you write:
```json
"selectors": [{ "source": ".*analytics.*", "group": "analytics" }]
```

But your BI tool doesn't send `X-Trino-Source: analytics`, every query falls through to the default group with no concurrency cap.

**Requirements by client type:**
- JDBC: add `source=analytics` to the connection string
- CLI: pass `--source analytics`
- HTTP API: include header `X-Trino-Source: analytics`

Verify it's working:
```sql
SELECT "source" FROM system.runtime.queries
WHERE query LIKE '%app_pg%'
ORDER BY created DESC LIMIT 5;
```
The `source` field should show your client's value.

### 5. Example Configuration

**`etc/resource-groups.properties`** (coordinator):
```properties
resource-groups.configuration-manager=file
resource-groups.config-file=etc/resource-groups.json
```

**`etc/resource-groups.json`**:
```json
{
  "rootGroups": [
    {
      "name": "federation",
      "hardConcurrencyLimit": 30,
      "maxQueued": 200,
      "schedulingPolicy": "fair",
      "subGroups": [
        {
          "name": "analysts",
          "hardConcurrencyLimit": 2,
          "maxQueued": 50,
          "softMemoryLimit": "60%"
        },
        {
          "name": "default",
          "hardConcurrencyLimit": 10,
          "maxQueued": 100,
          "softMemoryLimit": "80%"
        }
      ]
    }
  ],
  "selectors": [
    {
      "source": ".*analyst.*",
      "group": "federation.analysts"
    },
    {
      "source": ".*",
      "group": "federation.default"
    }
  ]
}
```

After editing: **restart the coordinator** — file-based resource groups do not hot-reload.

Then verify in the Trino UI: the query detail page shows a "Resource group" field. If it shows a default group without your configured name, the selector didn't match — check your client's source header.

### 6. Why You Still Need PgBouncer

Resource groups cap concurrent Trino queries, but each query can open multiple Postgres connections (one per Postgres TableScan — a query joining two Postgres tables opens 2 connections). PgBouncer provides the Postgres-side safety ceiling:

- **Trino resource groups** (your ask): cap concurrent queries at the Trino level, before they reach Postgres
- **PgBouncer** (`default_pool_size: 50`) + **Postgres role** (`CONNECTION LIMIT 50` on the `trino` user): hard walls even if Trino's queuing has a gap

With `hardConcurrencyLimit: 2`:
- Best case: 2 queries × 1 Postgres table each = 2 connections
- Worst case: 2 queries × 3 Postgres tables each = 6 connections

PgBouncer's pool size and the Postgres role limit protect against the worst case. Both layers together prevent the connection spikes you're seeing.
