# Iter243 Q1 — Resource Groups: Separating JDBC Federation from Iceberg Queries

## What Resource Groups Do

Trino's resource groups act as a **concurrency limiter and queue manager** for queries. They sit at the query layer — after your HTTP connection is accepted, but before queries run on workers. You define groups, set concurrency caps (`hardConcurrencyLimit`), and use **selectors** (rules) to route different queries to different groups based on who's running them, what type of query it is, or where the query came from (`source`).

This is **not** a connection pool. It's a query-level admission control system. But it's exactly what you need to prevent federation queries from starving your Iceberg queries.

## The Setup: Two Resource Groups with Source Routing

The key insight is using the **`source` field in selectors** — a client-supplied string that identifies what type of workload is submitting the query. This is how you separate your Postgres federation queries from your Iceberg-only queries.

### Step 1: Configure Resource Groups

Create `etc/resource-groups.json` on your Trino coordinator:

```json
{
  "rootGroups": [
    {
      "name": "federation",
      "softMemoryLimit": "20%",
      "hardConcurrencyLimit": 10,
      "maxQueued": 50,
      "schedulingPolicy": "fair"
    },
    {
      "name": "analytical",
      "softMemoryLimit": "50%",
      "hardConcurrencyLimit": 30,
      "maxQueued": 200,
      "schedulingPolicy": "fair"
    }
  ],
  "selectors": [
    {
      "user": ".*",
      "queryType": "SELECT",
      "source": ".*federation.*",
      "group": "federation"
    },
    {
      "user": ".*",
      "queryType": "SELECT",
      "source": ".*iceberg.*",
      "group": "analytical"
    },
    {
      "user": ".*",
      "group": "analytical"
    }
  ]
}
```

What this does:
- **`federation` group**: caps Postgres federation queries at 10 concurrent, with 50 in the queue. Any 11th federation query waits; any 61st is rejected.
- **`analytical` group**: allows 30 concurrent queries for your Iceberg workload (or any query that doesn't match the federation selector). These queries are **completely isolated** from the federation concurrency limit — they never compete for the same 10 slots.
- The **selectors** (rules) route queries based on the `source` string the client sets. They're evaluated top-to-bottom; first match wins.
- The **catch-all** last selector (no matchers) sends any untagged queries to `analytical` to avoid "no matching resource group found" rejections.

### Step 2: Wire the Resource Groups to Your Coordinator

Create a **separate file** called `etc/resource-groups.properties` (NOT in `config.properties` — this is a common mistake):

```properties
resource-groups.configuration-manager=file
resource-groups.config-file=etc/resource-groups.json
```

Then **restart the coordinator**.

### Step 3: Make Clients Set the Source

Now you must tell your clients which source string to use so the selectors can route them correctly.

**For your dashboard/federation queries** (hitting Postgres), set source to include "federation":

1. **JDBC connection URL** (if you're pooling Trino connections in your API):
   ```
   jdbc:trino://coordinator:8443/iceberg?source=dashboard-federation-queries
   ```

2. **CLI** (for ad-hoc federation queries):
   ```bash
   trino --server coordinator:8443 --source federation-queries --catalog iceberg
   ```

3. **HTTP header** (for direct REST calls):
   ```
   X-Trino-Source: federation-queries
   ```

**For your Iceberg-only queries** (reporting, analytics), set source to include "iceberg":
```
jdbc:trino://coordinator:8443/iceberg?source=analytics-iceberg-queries
```

The exact source names don't matter — they just need to **match the regex patterns in the selectors**.

## How the Separation Actually Works

When a heavy Postgres federation query lands:
1. Trino sees `source=federation-queries`.
2. The selector matches it to the `federation` group.
3. If fewer than 10 queries are running in that group, the query is admitted immediately.
4. If exactly 10 are running, the new query waits in the `federation` queue (up to 50 deep).
5. Meanwhile, Iceberg-only queries matching `.*iceberg.*` source go to the `analytical` group, which has **its own separate 30-concurrency budget**.

**The Iceberg queries are unaffected by Postgres queries** — they never share the same hardConcurrencyLimit slots.

## Key Properties Explained

| Property | What it does |
|---|---|
| `hardConcurrencyLimit` | **Hard cap** on concurrent queries in this group. The 11th query waits or is rejected. |
| `softMemoryLimit` | Percentage of cluster memory the group can use. When exceeded, Trino throttles (doesn't reject). |
| `maxQueued` | How many queries can wait before new submissions are rejected with `QUERY_QUEUE_FULL`. |
| `source` in selectors | The free-form string the client provides. Regex-matched. **If the client doesn't set source, the query falls through to the catch-all group.** |

## Verification Checklist

1. **Confirm clients ARE setting source**:
   ```sql
   SELECT "source", query_id, created FROM system.runtime.queries 
   WHERE query LIKE '%app_pg%' 
   ORDER BY created DESC LIMIT 5;
   ```
   The `source` column should show your federation source string, not `null`.

2. **Verify queries land in the right group** — in the Trino UI, check each running query's "Resource group" field.

3. **Test isolation** — submit 10 federation queries that each take 30 seconds. While running, submit an Iceberg query. It should **not wait** — it gets one of your 30 analytical slots immediately.

## Critical Gotcha

**`"rootGroups"` not `"groups"`** — the top-level key must be `"rootGroups"`. Using `"groups"` silently fails and your config is ignored. Also, every group name referenced in a selector (`"group": "federation"`) must be defined in `rootGroups`; an undefined group name causes that selector to silently not apply.

## Practical Tuning

Start conservative:
- Federation `hardConcurrencyLimit=10` — limits Postgres connection pressure (each query opens 1–5 JDBC connections depending on how many tables it touches).
- Analytical `hardConcurrencyLimit=30` — gives Iceberg plenty of headroom.

Observe production, then raise limits as needed. Raising one group's limit never affects the other — they're independent budgets.
