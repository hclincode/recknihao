# Iter67 Q1 — Answer

**Question**: We have maybe 15 customers all querying the same Trino cluster against their respective analytics data. One of our larger customers runs really heavy reports — like they'll kick off a query that scans months of data — and whenever that happens, everyone else's dashboards slow to a crawl or time out completely. Right now they're all just hitting the same cluster with no separation. I've heard there's some way to set limits or priorities on queries by user or group, but I don't really know how Trino handles that. Is there a way to carve out resources per customer so that one tenant's expensive query can't starve out everyone else? How does that actually get configured?

---

## Answer

Yes. Trino resource groups are exactly the feature you need. Here's how they work and how to configure them for your 15-tenant setup.

### What resource groups are

A **resource group** is a named query queue that enforces limits on how much cluster capacity a given user or group of users can consume. Instead of all 15 customers sharing one unbounded pool, you create a group per tenant (or per tier) with specific concurrency and memory caps. When a tenant hits their limit, new queries from that tenant wait in a queue rather than consuming cluster resources — so other tenants remain unaffected.

The key: resource groups match on **JWT principal** (the `sub` claim from the JWT token), which is exactly what your on-prem stack uses for authentication. Each tenant's service account authenticates with its own JWT identity, and Trino routes that identity to the right group.

### The four critical config fields

These exact property names are required. Using wrong names (like `maxRunning` or `maxMemoryPercent`) causes the limits to be silently ignored — no error, the config just does nothing.

| Field | What it controls | Example |
|---|---|---|
| `hardConcurrencyLimit` | Maximum simultaneously running queries in this group | `5` |
| `softMemoryLimit` | Memory ceiling; new queries queue when exceeded | `"20%"` or `"10GB"` |
| `maxQueued` | Max queries waiting in the queue; beyond this, queries are rejected immediately | `50` |
| `subGroups` | Nested child groups for hierarchical limits | (array) |

### Concrete configuration for 15 tenants

Place this at `etc/resource-groups.json` on your Trino coordinator pod (or mount it via Kubernetes ConfigMap):

```json
{
  "rootGroups": [
    {
      "name": "global",
      "softMemoryLimit": "90%",
      "hardConcurrencyLimit": 100,
      "maxQueued": 500,
      "subGroups": [
        {
          "name": "heavy_tenants",
          "softMemoryLimit": "35%",
          "hardConcurrencyLimit": 30,
          "maxQueued": 150,
          "subGroups": [
            {
              "name": "large_cust_acme",
              "softMemoryLimit": "20%",
              "hardConcurrencyLimit": 10,
              "maxQueued": 50
            }
          ]
        },
        {
          "name": "standard_tenants",
          "softMemoryLimit": "50%",
          "hardConcurrencyLimit": 60,
          "maxQueued": 300,
          "subGroups": [
            {
              "name": "tenant_default",
              "softMemoryLimit": "3%",
              "hardConcurrencyLimit": 2,
              "maxQueued": 20
            }
          ]
        },
        {
          "name": "internal_admin",
          "softMemoryLimit": "5%",
          "hardConcurrencyLimit": 10,
          "maxQueued": 100
        }
      ]
    }
  ],
  "selectors": [
    {
      "user": "acme-service-account",
      "group": "global.heavy_tenants.large_cust_acme"
    },
    {
      "user": "tenant-.*",
      "group": "global.standard_tenants.tenant_default"
    },
    {
      "user": "data-engineering",
      "group": "global.internal_admin"
    }
  ]
}
```

This gives your largest customer (Acme) up to 10 concurrent queries and 20% of cluster memory. All other standard tenants each get at most 2 concurrent queries and 3% memory. Your internal data team gets its own slice that can always run regardless of tenant load.

### The critical gotcha: selectors match JWT principal, not role name

The `"user"` field in each selector is a **Java regex** matched against the **JWT subject** (the `sub` claim), NOT the Trino role name. If your tenant's app authenticates with JWT principal `acme-service-account`, the selector must match `acme-service-account`.

If you write a selector matching `acme_role` but the JWT subject is `acme-service-account`, the selector silently never fires. The query lands in whatever falls through to the last selector — often an uncapped group. This is the most common deployment mistake, and there is no error message to catch it.

### How to verify queries land in the right group

After deployment, confirm selectors are matching correctly by querying `resource_group_id` in `system.runtime.queries`:

```sql
SELECT query_id, user, state, resource_group_id, started
FROM system.runtime.queries
WHERE state IN ('RUNNING', 'QUEUED')
ORDER BY started DESC
LIMIT 20;
```

If a tenant's queries show `resource_group_id = 'global'` instead of `global.heavy_tenants.large_cust_acme`, the selector didn't match. Fix the regex and reload the config.

You can also diagnose queue depth per group:

```sql
SELECT resource_group_id, COUNT(*) AS query_count, state
FROM system.runtime.queries
WHERE state IN ('RUNNING', 'QUEUED')
GROUP BY resource_group_id, state
ORDER BY resource_group_id, state;
```

### File-based vs database-backed: restart vs hot-reload

**File-based (default, what you have now):**
- Edit `etc/resource-groups.json` and restart the Trino coordinator.
- Restart drops in-flight queries and causes a brief outage window (~10–30 seconds).
- Changes take effect immediately for all new queries after restart.

**Database-backed (recommended if you adjust limits frequently):**
- Store resource group config in a small Postgres database.
- Trino re-reads it every 1 second — changes take effect in seconds, no restart needed.
- Enable it in `etc/resource-groups.properties`:

```properties
resource-groups.configuration-manager=db
resource-groups.config-db-url=jdbc:postgresql://rg-config-db:5432/trino_rg
resource-groups.config-db-user=trino_rg
resource-groups.config-db-password=<secret>
resource-groups.refresh-interval=1s
```

For a 15-tenant cluster where you onboard customers frequently, the database-backed manager is worth the extra Postgres dependency — no restart needed when adding a new tenant's group.

### What to do right now if Acme is currently choking the cluster

Resource group config changes only apply to new queries. An already-running 500GB scan is not affected by reloading config. To get resources back immediately:

```sql
-- Kill the runaway query using its query_id from system.runtime.queries
CALL system.runtime.kill_query(
  query_id => '20260525_140522_00123_abc',
  message  => 'Throttling per incident — contact support'
);
```

Then deploy the resource group config so the next query from that tenant is capped before it can cause the same problem.

### Steps to deploy

1. Write `etc/resource-groups.json` with your 15 tenants' groups and selectors.
2. Verify JWT principal names (ask your auth team or check Trino HTTP event logs for the `user` field in recent queries).
3. Mount the config file in your Trino coordinator's Kubernetes ConfigMap.
4. Restart the coordinator.
5. Run a test query as each tenant and confirm `resource_group_id` in `system.runtime.queries` shows the expected group.
6. Run a deliberately heavy query as Acme and confirm other tenants' queries remain unaffected.
