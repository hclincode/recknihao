# Iter248 Q2 — Resource Groups for Federated Query Isolation

## Answer

Yes, absolutely — Trino resource groups are exactly the tool for this. They let you cap concurrent queries on a per-workload basis and give different groups different concurrency limits. In your case, you can create one resource group for ETL batch jobs (high priority, fewer but dedicated slots) and another for ad-hoc federated analytics queries (lower priority, capped concurrency).

**The core idea:** Resource groups act as admission gates. When a query lands on the coordinator, Trino checks which group it belongs to (via selectors), and either lets it run immediately, queues it, or rejects it if the group is full. This is exactly what starves you — you can set a hard concurrency limit per group so that when your ETL job arrives, it doesn't fight 50 ad-hoc dashboard queries for the same worker pool.

### How Trino identifies which query belongs to which group

Trino uses **selectors** — rules that match incoming queries and assign them to resource groups. A selector can match on:

- **`user`** — which Trino principal submitted the query (e.g., `spark-ingest`, `analytics-user`)
- **`queryType`** — the SQL statement type: `SELECT`, `INSERT`, `CREATE`, `UPDATE`, `DELETE`
- **`source`** — a free-form string the client sets when submitting the query (e.g., `"spark-etl"`, `"grafana-dashboard"`, `"adhoc-analyst"`)

The **`source`** field is the most practical for your scenario. When your Spark ETL job connects to Trino, it sets `source=spark-etl`. When your analytics team queries via their BI tool or CLI, they set `source=analytics-federation`. Trino's selectors match these strings and route queries to the right group.

### Configuration: a worked example for your scenario

Create a file called `etc/resource-groups.json` on the Trino coordinator:

```json
{
  "rootGroups": [
    {
      "name": "etl_batch",
      "softMemoryLimit": "50%",
      "hardConcurrencyLimit": 5,
      "maxQueued": 10,
      "schedulingPolicy": "fifo"
    },
    {
      "name": "federation_adhoc",
      "softMemoryLimit": "30%",
      "hardConcurrencyLimit": 15,
      "maxQueued": 100,
      "schedulingPolicy": "fair"
    },
    {
      "name": "default_group",
      "softMemoryLimit": "20%",
      "hardConcurrencyLimit": 30,
      "maxQueued": 200,
      "schedulingPolicy": "fair"
    }
  ],
  "selectors": [
    {
      "user": "spark-ingest",
      "source": "spark-etl",
      "group": "etl_batch"
    },
    {
      "user": ".*analytics.*",
      "source": ".*federation.*",
      "group": "federation_adhoc"
    },
    {
      "user": ".*",
      "group": "default_group"
    }
  ]
}
```

**What this does:**

- **`etl_batch` group**: Up to 5 Spark ETL jobs can run concurrently. When the 6th arrives, it goes into a queue of 10. After 10 are queued, new ones are rejected. FIFO scheduling means "first in, first out" — fair for batch jobs with predictable start times.
- **`federation_adhoc` group**: Up to 15 ad-hoc federated queries run concurrently. When the 16th arrives, it waits. Fair scheduling means concurrent queries share resources evenly.
- **`default_group`**: Catch-all for anything that doesn't match the first two selectors.

The **selectors array** is evaluated top-to-bottom. The first rule that matches wins.

### How to wire resource groups into Trino

1. **Create two separate files** on the coordinator:

   - `etc/resource-groups.properties` (the wiring):
     ```properties
     resource-groups.configuration-manager=file
     resource-groups.config-file=etc/resource-groups.json
     ```

   - `etc/resource-groups.json` (the config above)

2. **In Kubernetes**: Mount both files via ConfigMaps into the coordinator pod.

3. **Restart the coordinator** — resource groups are not hot-reloadable. Changes require a pod restart.

### How your clients set the `source` field

Your **Spark ETL job** needs to connect with the source set. In connection properties:

```python
conn_properties = {
  "user": "spark-ingest",
  "source": "spark-etl",  # this is what the selector matches
}
```

Your **analytics team's CLI or BI tool**:

```bash
# Trino CLI
trino --server coordinator:8080 --source federation-queries

# JDBC URL (for Grafana, Looker, Tableau):
jdbc:trino://coordinator:8080/iceberg/analytics?source=analytics-federation-dashboard
```

### What happens at query time

1. Your analytics team runs a slow federated Postgres join tagged with `source=analytics-federation-dashboard` → lands in `federation_adhoc`.
2. That group already has 15 queries running → new query goes into the queue.
3. Simultaneously, your Spark ETL batch job submits with `source=spark-etl` → matches `etl_batch` → admits immediately because only 2 of 5 slots are used.
4. ETL job completes on schedule. Ad-hoc queries execute as slots free up.

### Key tuning parameters

| Parameter | ETL batch | Ad-hoc federation |
|---|---|---|
| `hardConcurrencyLimit` | 5 (few long-running jobs) | 15 (many short queries) |
| `maxQueued` | 10 (queued batch = mistake) | 100 (dashboard users expect waits) |
| `schedulingPolicy` | `fifo` | `fair` |
| `softMemoryLimit` | 50% (batch is memory-intensive) | 30% |

### Verification

After restarting the coordinator, check that a query lands in the right group:

```sql
SELECT query_id, state, "source", resource_group_id
FROM system.runtime.queries
WHERE query LIKE '%app_pg%'
ORDER BY created DESC
LIMIT 5;
```

The `resource_group_id` column should show `federation_adhoc`. If it shows `default_group`, either the client isn't setting `source` or the selector regex isn't matching.

### Common pitfalls

1. **`"groups"` instead of `"rootGroups"`** in the JSON — coordinator won't start.
2. **Selector references a group that doesn't exist** — queries silently fall through to default group.
3. **Client not setting source** — queries land in default group regardless of selector rules.
4. **Confusing resource groups with HTTP connection limits** — resource groups cap concurrent queries after they land on the coordinator; `http-server.max-concurrency` caps incoming HTTP connections before that layer.
