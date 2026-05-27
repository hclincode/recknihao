# Iter105 Q1 — Answer

**Question**: We have about 120 customers now, and I'm getting pressure from our sales team to offer each enterprise customer their own dedicated analytics view — basically, they want to white-label the dashboard so each customer only ever sees their own data. Right now everything is in shared Postgres tables with a tenant_id column. My concern is: what happens if I accidentally write a query that forgets the WHERE tenant_id = ? filter? In Postgres I can kind of get away with it because the app layer always passes that filter before hitting the DB. But if we move to a separate analytics system, how do I make sure there's a hard enforcement layer that just makes it impossible to leak one customer's data to another, even if a developer writes a bad query?

---

## Answer

Your concern is exactly right — **never rely on the application layer once you have a separate analytics system**. A forgotten `WHERE tenant_id = ?` in Trino leaks every customer's data at once, because the base table holds all tenants' rows with nothing stopping a `SELECT *` from scanning everything.

The standard solution is **per-tenant Trino views with OPA access control**. This makes data leakage technically impossible — the query engine itself rejects base-table access before any files are opened.

### The Pattern: Views as the Only Path to Data

**Step 1: Create the shared base table (admin access only)**

```sql
CREATE TABLE iceberg.analytics.events (
  event_id    BIGINT,
  tenant_id   VARCHAR,
  user_id     VARCHAR,
  event_type  VARCHAR,
  event_ts    TIMESTAMP,
  payload     VARCHAR
)
WITH (
  partitioning = ARRAY['tenant_id', 'day(event_ts)']
);
```

Partition by `tenant_id` first — this makes Iceberg store each tenant's files separately, enabling file-level pruning on per-tenant queries.

**Step 2: Create a view per tenant**

```sql
-- PREREQUISITE: create the schema (Trino does NOT auto-create schemas)
CREATE SCHEMA IF NOT EXISTS tenant_acme;

-- The WHERE clause is the isolation boundary
CREATE VIEW tenant_acme.events AS
  SELECT event_id, user_id, event_type, event_ts, payload
  FROM iceberg.analytics.events
  WHERE tenant_id = 'acme';
```

Trino views use **SECURITY DEFINER** by default — the view body runs with the view owner's grants (a privileged internal account), not the querying tenant's grants. The tenant needs SELECT on the view, not on the base table. Even if a tenant writes `SELECT * FROM iceberg.analytics.events`, they get Access Denied.

**Step 3: Create a role and grant only the view**

```sql
CREATE ROLE acme_role;
GRANT ROLE acme_role TO USER "acme-service-account";

-- Grant SELECT on the VIEW only — never on the base table
GRANT SELECT ON tenant_acme.events TO ROLE acme_role;
```

**Step 4: Revoke base-table access from the user principal**

```sql
-- REVOKE from the USER (not the role) — Trino allows access by default
REVOKE ALL PRIVILEGES ON iceberg.analytics.events FROM USER "acme-service-account";
```

**Step 5: Verify isolation**

```sql
-- As acme-service-account:
SELECT count(*) FROM tenant_acme.events;           -- MUST succeed, Acme rows only
SELECT count(*) FROM iceberg.analytics.events;     -- MUST fail: Access Denied
SELECT count(*) FROM tenant_beta.events;           -- MUST fail: Access Denied
```

### The OPA Layer: Three Rules That Prevent Leaks

Your stack uses OPA as the Trino authorization backend. Three deny rules make isolation robust:

1. **Deny base-table access to tenant principals**: If principal is a tenant service account and the table is a base Iceberg table (not a view), deny. This makes the view the only read path.

2. **Deny Iceberg metadata tables**: If the table name contains `$` (e.g., `events$partitions`, `events$files`, `events$snapshots`), deny for tenant principals. These metadata tables expose every tenant's data volumes and row counts.

3. **Deny the system catalog**: If the catalog is `system`, deny for tenant principals. The `system.runtime.queries` table shows every query running on the cluster — a complete cross-tenant data leak if exposed.

Specific OPA Rego policy code belongs in your external governance document, but these three rules are the conceptual foundation.

### Why This Makes Data Leaks Impossible

A developer writes:
```sql
-- Authenticated as acme-service-account
SELECT * FROM iceberg.analytics.events;
```

What happens:
1. Trino receives the query.
2. Trino's analyzer calls OPA: "is `acme-service-account` allowed to SELECT from `iceberg.analytics.events`?"
3. OPA denies: "no — tenant principals can only read tenant-scoped views."
4. Trino returns **Access Denied**, before any worker starts, before any file opens.

**The query engine enforces the boundary — not the application code.** A developer cannot accidentally leak data regardless of what SQL they write.

### Don't Give Tenant Admins Base-Table Access

**Wrong:**
```sql
GRANT SELECT ON iceberg.analytics.events TO ROLE acme_admin;
-- This gives the admin ALL tenants' data
```

**Right — use views for admin roles too:**
```sql
CREATE VIEW tenant_acme.events_admin AS
  SELECT * FROM iceberg.analytics.events
  WHERE tenant_id = 'acme';

GRANT SELECT ON tenant_acme.events_admin TO ROLE acme_admin;
REVOKE ALL PRIVILEGES ON iceberg.analytics.events FROM ROLE acme_admin;
```

### Add a CI Test for Isolation

```sql
-- Run these as part of your test suite against each new tenant setup:

-- Test 1: tenant can read their own data (must succeed)
SELECT * FROM tenant_acme.events LIMIT 1;

-- Test 2: tenant cannot read base table (must fail with Access Denied)
SELECT * FROM iceberg.analytics.events;

-- Test 3: tenant cannot read system queries (must fail)
SELECT * FROM system.runtime.queries;

-- Test 4: tenant cannot read metadata tables (must fail)
SELECT * FROM iceberg.analytics."events$partitions";
```

Catching an isolation breach in CI is far better than discovering it in production.

### Resource Groups: Prevent Noisy Neighbors

A separate concern: one tenant running a large aggregation can starve other tenants' queries. Configure per-tenant resource groups in `etc/resource-groups.properties`:

```json
{
  "rootGroups": [{
    "name": "global",
    "softMemoryLimit": "80%",
    "hardConcurrencyLimit": 100,
    "subGroups": [
      {"name": "tenant_acme", "softMemoryLimit": "20%", "hardConcurrencyLimit": 5},
      {"name": "tenant_beta", "softMemoryLimit": "20%", "hardConcurrencyLimit": 5}
    ]
  }],
  "selectors": [
    {"user": "acme-service-account", "group": "global.tenant_acme"},
    {"user": "beta-service-account", "group": "global.tenant_beta"}
  ]
}
```

Each tenant is capped at 20% of cluster memory and 5 concurrent queries — a rogue query from one customer can't take down the entire cluster.

### Implementation Checklist for 120 Customers

- [ ] Partition base table by `(tenant_id, day(event_ts))`
- [ ] Create one schema per tenant: `CREATE SCHEMA IF NOT EXISTS tenant_<id>`
- [ ] Create one view per tenant with `WHERE tenant_id = '<id>'`
- [ ] Create one role per tenant; grant SELECT on view only
- [ ] Revoke ALL on base table from each tenant's user principal
- [ ] Configure OPA with the three deny rules above
- [ ] Add per-tenant resource group entries
- [ ] Run isolation tests in CI for every new tenant onboarded
