# Iter268 Q1 — Updating Resource Group Limits Without Restart

## Answer

Whether you can update resource group limits without restarting Trino depends on which configuration manager you are using. There are two options, and they have very different behavior.

### The Two Configuration Managers

**Option 1: File-based (most common default)**

If your `etc/resource-groups.properties` contains:
```properties
resource-groups.configuration-manager=file
resource-groups.config-file=etc/resource-groups.json
```

Then **changes to resource-groups.json require a coordinator restart** to take effect. There is no hot-reload. The file-based manager reads the config once at startup.

This is the standard setup for most on-prem Trino deployments. When you need to change `hardConcurrencyLimit` or `maxQueued`, you edit the JSON file and restart the coordinator. Active queries are allowed to finish; new queries queue until the coordinator comes back up. For a properly configured cluster, restart time is typically 15–30 seconds.

**Option 2: Database-based (supports live updates)**

If you use the database-backed manager, changes take effect without a restart:

```properties
# etc/resource-groups.properties
resource-groups.configuration-manager=db
resource-groups.config-db-url=jdbc:mysql://db.internal:3306/trino_rg
resource-groups.refresh-interval=10s
```

With `resource-groups.refresh-interval=10s`, Trino polls the database every 10 seconds and picks up any changes to the resource group configuration. You update limits by modifying the database, not a flat file.

The database-based manager adds operational complexity (requires maintaining a separate MySQL/PostgreSQL metadata database), but is the right choice if you need to change limits frequently without downtime.

**Property name warning**: There is no `resource-groups.config-refresh-period` or `resource-groups.reload-interval` property. Setting either in your properties file will cause coordinator startup failure with "unknown configuration property" error. The only valid hot-reload property is `resource-groups.refresh-interval`, and it only works with `configuration-manager=db`.

### Practical Advice for Your Situation

If you are on the file-based manager (most likely), the immediate fix for dashboard starvation is:

1. **Edit `etc/resource-groups.json`** — increase `hardConcurrencyLimit` for the dashboard subgroup, decrease it for the background jobs group, or add `schedulingWeight` to prioritize dashboard queries
2. **Restart the coordinator** — the restart is brief; active queries on workers continue running
3. **Consider adding a low-weight background group** — the `schedulingWeight` property lets you say "when the cluster is contended, dashboards get 10x more scheduling attention than export jobs":

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
        "hardConcurrencyLimit": 20,
        "maxQueued": 100,
        "softMemoryLimit": "40%",
        "schedulingWeight": 10
      },
      {
        "name": "exports",
        "hardConcurrencyLimit": 3,
        "maxQueued": 20,
        "softMemoryLimit": "30%",
        "schedulingWeight": 1
      },
      {
        "name": "global",
        "hardConcurrencyLimit": 10,
        "maxQueued": 50,
        "softMemoryLimit": "20%",
        "schedulingWeight": 2
      }
    ]
  }],
  "selectors": [
    { "source": "dashboard-.*", "group": "federation.dashboards" },
    { "source": "export-.*",    "group": "federation.exports" },
    { "group": "federation.global" }
  ]
}
```

Note: the catch-all selector `{ "group": "federation.global" }` targets the leaf group `federation.global`, not the parent `federation`. Selectors must always route to leaf groups (groups with no `subGroups`).

### How to Verify a Query Landed in the Right Group

After restarting (or after updating the database for db-based config), check routing with this query:

```sql
SELECT
  query_id,
  "user",
  source,
  resource_group_id,
  state,
  queued_time_ms,
  elapsed_time_ms
FROM system.runtime.queries
WHERE state IN ('RUNNING', 'QUEUED')
ORDER BY created DESC
LIMIT 20;
```

The `resource_group_id` column shows exactly which group each query landed in. For example:
- `federation.dashboards` — routed correctly to the dashboard group
- `federation.exports` — routed to exports
- `federation.global` — caught by the catch-all (may mean the `source` wasn't set by the client)

If queries are landing in the wrong group, the most common cause is that the client is not setting the `source` property. Clients must set it explicitly:
- **JDBC URL**: `jdbc:trino://host:8080/catalog?source=dashboard-service`
- **Trino CLI**: `trino --source=dashboard-service`

If `source` is not set, the source-based selectors won't match, and the query falls through to the catch-all group.

### Summary

| Configuration Manager | Hot-Reload? | How to Update |
|---|---|---|
| `file` (default) | No — restart required | Edit JSON file → restart coordinator |
| `db` | Yes — via `resource-groups.refresh-interval` | Update database row → live within refresh interval |

For most on-prem setups, file-based is fine — restarts are brief and the isolation benefit (dashboards no longer starved by exports) is immediate.
