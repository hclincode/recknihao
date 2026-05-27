# Iter62 Q1 — Answer

**Question**: We set up Trino resource groups a few weeks ago to make sure one customer's heavy queries don't starve everyone else out. My manager is asking me to prove it's actually working before we roll it out to more tenants. Is there some way to query Trino to see which resource group a given query was assigned to, or to see the current queue depth per group? I'm basically trying to build a quick audit — something I can run after a deploy to confirm the config took effect. Also, we had a coordinator pod restart last week and I'm not sure if the resource group state survived that. Does it reset, and is there anything we need to do after a restart to make sure it's enforcing correctly again?

---

## Answer

Yes, you can audit resource groups directly with SQL. The key column is `resource_group_id` on `system.runtime.queries`.

### Querying which resource group a query is assigned to

```sql
SELECT query_id, user, state, resource_group_id, created
FROM system.runtime.queries
WHERE state IN ('RUNNING', 'QUEUED')
ORDER BY created DESC;
```

The `resource_group_id` column shows the full dotted group path — e.g., `global.tenant_acme` or `global.tenant_standard`. If a query shows `global` instead of your expected subgroup, the selector didn't match that query's JWT principal.

This is the authoritative audit tool. If `resource_group_id` shows `global.tenant_acme` for Acme's queries, the config is working. If it shows `global`, your selector's `"user"` regex doesn't match the actual authenticated username — check for typos or case mismatches.

### Checking queue depth per resource group

```sql
SELECT
  resource_group_id,
  state,
  COUNT(*) AS query_count
FROM system.runtime.queries
WHERE state IN ('RUNNING', 'QUEUED')
GROUP BY resource_group_id, state
ORDER BY resource_group_id, state;
```

This shows how many queries are running vs queued in each group right now. If a group is at its `hardConcurrencyLimit` (all slots running) and more are QUEUED, the limits are enforcing correctly.

### Post-deploy verification checklist

After deploying a config change:

1. Run a test query as the tenant's service account:
   ```sql
   SELECT 1;
   ```

2. Check which group it landed in:
   ```sql
   SELECT query_id, user, resource_group_id
   FROM system.runtime.queries
   WHERE user = 'acme-service-account'
   ORDER BY created DESC
   LIMIT 1;
   ```
   Should show `global.tenant_acme`, not `global`.

3. Submit more queries than the `hardConcurrencyLimit` and verify the extras are QUEUED:
   ```sql
   -- After submitting 10 concurrent queries from a group with hardConcurrencyLimit=5:
   SELECT resource_group_id, state, COUNT(*)
   FROM system.runtime.queries
   WHERE user = 'acme-service-account'
   GROUP BY resource_group_id, state;
   -- Expected: 5 RUNNING, 5 QUEUED
   ```

### What happens to resource group state after a coordinator restart

For file-based resource group config (`resource-groups.json`):

- **Config survives**: The JSON file is mounted via ConfigMap in Kubernetes — it's persistent.
- **In-flight queries die**: All running and queued queries are dropped when the coordinator restarts. The queue is wiped.
- **New queries use the fresh config immediately**: After restart, the first query is already subject to the limits. No warm-up period.
- **State resets**: The group's running/queued counts reset to zero. Tenants start fresh.

**Important**: File-based resource group config is NOT hot-reloaded. A ConfigMap update alone does nothing until the coordinator pod is restarted. This is why during a live incident the correct sequence is: (1) kill offending queries with `CALL system.runtime.kill_query()` for immediate relief, (2) update the ConfigMap, (3) restart the coordinator to apply new limits.

After restart, run the audit queries above — they'll show empty results initially (no queries yet), then populate as tenants reconnect. All new queries should land in the correct subgroups.

### The silent failure trap: wrong field names

Trino silently ignores unknown property names. If you're seeing queries land in `global` instead of subgroups, check for these common typos:

| Wrong (silently ignored) | Correct |
|---|---|
| `maxConcurrentQueries` | `hardConcurrencyLimit` |
| `maxRunning` | `hardConcurrencyLimit` |
| `maxMemoryPercent` | `softMemoryLimit` (value like `"20%"`) |
| `userRegex` | `"user"` (just `user`, but value is a Java regex) |

No error appears when you deploy wrong field names — the coordinator starts fine and the config loads. But the limit fields are simply never read.

### Alternative: database-backed resource group manager

If you need config changes to take effect without a coordinator restart, Trino supports a database-backed resource group manager that hot-reloads every 1 second:

```properties
# etc/resource-groups.properties
resource-groups.configuration-manager=db
resource-groups.config-db-url=jdbc:postgresql://postgres:5432/trino_rg
```

With the `db` manager, you update resource group rows in the database and Trino picks up the changes automatically — no restart needed. The trade-off is an additional Postgres/MySQL dependency and slightly more operational complexity. For most on-prem teams with infrequent limit adjustments, file-based config with a planned coordinator restart window is simpler.
