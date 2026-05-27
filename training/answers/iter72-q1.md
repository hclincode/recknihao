# Iter72 Q1 — Answer

**Question**: We're using Trino resource groups to limit how many queries each tenant can run at the same time. The config lives in a `resource-groups.json` file. Every time we sign up a new customer, someone has to manually add them to that file, and then we have to restart the Trino coordinator to pick up the change. During that restart, the query engine is just down. We're onboarding customers more frequently now and this is becoming a real problem. I've been told there's a way to make Trino pick up resource group changes without restarting — what would I actually need to do to fix this?

---

## Answer

You're facing a genuine operational problem, and the fix is well-defined: switch from the file-based resource group manager to the database-backed resource group manager. Trino ships both; you're currently using the one that requires restart. Here's exactly what changes and what it takes.

### Why file-based config requires restart

Trino reads `resource-groups.json` **once at startup**. It does not watch the file for changes. When you add a new tenant entry to the file, Trino has no mechanism to pick it up without a restart. The coordinator restart drops all in-flight queries and causes 10–30 seconds of downtime — a real problem as you scale tenant count.

### The solution: database-backed resource groups

Trino has a built-in alternative configuration manager that stores resource group definitions in a database (Postgres or MySQL). The key difference: **Trino re-reads the database approximately every 1 second**. Changes take effect within a second or two, with no coordinator restart needed, ever.

This is not a plugin or custom feature — it's built into Trino. You're changing where the config is stored, not how resource groups work.

### What changes in Trino's configuration

**Current `etc/resource-groups.properties`:**
```properties
resource-groups.configuration-manager=file
resource-groups.config-file=etc/resource-groups.json
```

**New `etc/resource-groups.properties`:**
```properties
resource-groups.configuration-manager=db
resource-groups.config-db-url=jdbc:postgresql://rg-config-db:5432/trino_rg
resource-groups.config-db-user=trino_rg
resource-groups.config-db-password=<secure-password>
resource-groups.refresh-interval=1s
```

That's the only change to Trino's config files. Everything else — group names, selectors, limits — moves to the database.

### What you need to deploy

**1. A small Postgres instance** dedicated to resource group configuration. On your Kubernetes cluster, this is a small Postgres pod (or an external Postgres VM). It doesn't need to be large — it holds a few tables of group definitions and selector rules. For availability, a simple 2-node Postgres HA setup is sufficient.

**2. The database schema.** Trino automatically creates the required tables when it first connects (on the one-time migration restart). No manual schema setup needed.

**3. A way to insert tenant rows.** Your tenant onboarding script INSERTs rows into the database instead of editing JSON. Something like:

```sql
-- Add new tenant "gamma" to the resource group database
INSERT INTO resource_groups (name, soft_memory_limit, hard_concurrency_limit, max_queued, parent)
VALUES ('tenant_gamma', '15%', 3, 30, (SELECT id FROM resource_groups WHERE name = 'global'));

INSERT INTO selectors (resource_group_id, user_regex)
VALUES (
  (SELECT id FROM resource_groups WHERE name = 'tenant_gamma'),
  'gamma-service-account'
);
```

Within 1 second, Trino picks up the new group and starts routing `gamma-service-account` queries to it. No downtime. No file edit. No restart.

### Migration steps

1. Stand up a Postgres instance on your Kubernetes cluster (one small pod or existing Postgres service).
2. Update `etc/resource-groups.properties` to point at the new DB.
3. Perform **one final coordinator restart** to apply the new configuration and initialize the database schema. This is the last restart you'll do for resource group changes.
4. Migrate your existing tenant groups from the JSON file to database rows (a one-time data migration, takes a few minutes).
5. After the restart, queries resume. Future tenant additions are database INSERTs — no downtime.

### One important caveat: new operational dependency

Switching to DB-backed adds one dependency: if the resource group database goes down, Trino keeps using the **last successfully-read configuration** — queries continue running with the last-known limits. When the database comes back, Trino re-reads within a second and syncs. This is not worse than file-based (where a coordinator restart is also a full outage), but you need to monitor the config database and keep it healthy. Include it in your standard backup and HA procedures.

### The operational payoff

| Operation | File-based | DB-backed |
|---|---|---|
| Add new tenant | Edit JSON + coordinator restart (10–30s downtime) | INSERT row (< 2s, zero downtime) |
| Adjust tenant limits | Edit JSON + restart | UPDATE row (< 2s, zero downtime) |
| Roll back bad config | Edit JSON + restart | UPDATE row (< 2s) |
| Test new limits | Impossible without restart | Live: insert test row, watch it take effect |

Once you switch, onboarding a new customer is a database INSERT — scriptable, testable, and completely zero-downtime.
