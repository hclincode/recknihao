# Iter107 Q1 — Answer

**Question**: We have about 80 customers and they each get a usage dashboard showing things like their monthly active users and feature adoption. Right now when any of those dashboards load, the query runs as a Trino service account — the same one for all tenants. I realized that if there's ever a bug in our WHERE clause filtering by tenant_id, one customer could potentially see another's numbers. Someone suggested we should use separate Trino logins per customer instead of one shared service account. Is that actually how people solve this, and what does that look like in practice? Would we need 80 different database users or is there a smarter way?

---

## Answer

Yes — per-tenant service accounts (one per customer) are the standard pattern. But you don't need to create 80 Trino roles by hand. The smarter approach is: **one shared Iceberg table, one view per tenant, OPA enforces everything**. Adding customer #81 is a few SQL statements and an OPA policy update — no new infrastructure.

The key insight: your current setup relies on application code correctly injecting `WHERE tenant_id = ?` into every query. That's the fragile part. The fix is to move that filter into the **query engine itself** — a Trino view with a baked-in WHERE clause that runs regardless of what query the dashboard sends.

### How It Works: Per-Tenant Views as Enforcement Boundaries

**Step 1: Create the shared base table partitioned by tenant**

```sql
CREATE TABLE iceberg.analytics.events (
  event_id    BIGINT,
  tenant_id   VARCHAR,
  user_id     VARCHAR,
  event_type  VARCHAR,
  event_ts    TIMESTAMP
)
WITH (
  partitioning = ARRAY['tenant_id', 'day(event_ts)']
);
```

Partitioning by `tenant_id` first means Iceberg stores each tenant's files separately — Acme's queries never open Beta's files.

**Step 2: Create one view per tenant (the WHERE clause is locked in)**

```sql
-- PREREQUISITE: create schema first (Trino doesn't auto-create schemas)
CREATE SCHEMA IF NOT EXISTS tenant_acme;

-- The WHERE clause is the enforcement boundary — hardcoded, not injected by app code
CREATE VIEW tenant_acme.events AS
  SELECT event_id, user_id, event_type, event_ts
  FROM iceberg.analytics.events
  WHERE tenant_id = 'acme';
```

Trino views use **SECURITY DEFINER** by default — the view body runs with the view owner's privileges. Acme's service account needs SELECT on the view only, not on the base table.

**Step 3: Create a role and grant it to the per-tenant service account**

```sql
CREATE ROLE acme_role;
GRANT ROLE acme_role TO USER "acme-service-account";

-- Grant view access ONLY — never the base table
GRANT SELECT ON tenant_acme.events TO ROLE acme_role;
```

**Step 4: Revoke base-table access from the service account**

```sql
-- In a fresh Trino setup, there are no implicit grants — but be explicit:
REVOKE ALL PRIVILEGES ON iceberg.analytics.events FROM USER "acme-service-account";
```

**Result:** When the Acme dashboard runs `SELECT count(*) FROM analytics.events WHERE event_type = 'login'` (forgetting the tenant filter), Trino returns **Access Denied** — before the query even parses. The WHERE clause in the view is the filter. Your application code's WHERE clause is optional safety, not the enforcer.

### Why You Don't Need 80 Manual Roles: JWT + OPA

Your production stack uses **JWT authentication and OPA (Open Policy Agent) as the authorization backend**. This is where the "smarter way" lives.

Instead of creating 80 Trino roles via SQL:
- Your auth service issues a JWT to each tenant's backend with a `tenant_id` claim: `{"tenant_id": "acme", "sub": "acme-backend"}`
- OPA's policy (in your external governance document) says: "if JWT has `tenant_id = acme`, allow SELECT on `tenant_acme.*` views; deny everything else"
- Adding tenant #81 = issue an 81st JWT + create the views + update OPA's mapping

The SQL GRANT/REVOKE statements above are illustrative orientation — in an OPA-backed deployment, OPA is the actual enforcement. The view-as-isolation-boundary pattern is still required (it ensures the WHERE clause is always applied), but the mechanism that stops Acme from querying `iceberg.analytics.events` directly is OPA denying the request, not a REVOKE statement.

**OPA also blocks three other leak vectors automatically:**
- **Metadata tables** (`events$partitions`, `events$files`): expose per-tenant data volumes — OPA denies `$`-suffix table access to tenant principals
- **System catalog** (`system.runtime.queries`): shows every query running on the cluster including other tenants' SQL — OPA denies `system.*` to tenant principals
- **Other tenants' views** (`tenant_beta.events`): OPA denies access to any schema other than the principal's own

### Resource Groups: Preventing Noisy Neighbors

With 80 tenants sharing one cluster, one customer running a large aggregation can starve others. Configure per-tenant caps in `etc/resource-groups.json`:

```json
{
  "rootGroups": [{
    "name": "global",
    "softMemoryLimit": "80%",
    "hardConcurrencyLimit": 200,
    "subGroups": [
      {"name": "tenant_acme", "softMemoryLimit": "10%", "hardConcurrencyLimit": 5},
      {"name": "tenant_beta", "softMemoryLimit": "10%", "hardConcurrencyLimit": 5}
    ]
  }],
  "selectors": [
    {"user": "acme-service-account", "group": "global.tenant_acme"},
    {"user": "beta-service-account", "group": "global.tenant_beta"}
  ]
}
```

Note: resource groups are configured in `etc/resource-groups.json` (the JSON config file), **not** in `etc/resource-groups.properties` (which just points to the JSON file). The `.properties` file contains only:
```properties
resource-groups.configuration-manager=file
resource-groups.config-file=etc/resource-groups.json
```

### Onboarding a New Tenant (Checklist)

For tenant #81 ("omega"):

```sql
-- 1. Create schema
CREATE SCHEMA IF NOT EXISTS tenant_omega;

-- 2. Create view with baked-in filter
CREATE VIEW tenant_omega.events AS
  SELECT event_id, user_id, event_type, event_ts
  FROM iceberg.analytics.events
  WHERE tenant_id = 'omega';

-- 3. Create role and grant view access
CREATE ROLE omega_role;
GRANT ROLE omega_role TO USER "omega-service-account";
GRANT SELECT ON tenant_omega.events TO ROLE omega_role;
REVOKE ALL PRIVILEGES ON iceberg.analytics.events FROM USER "omega-service-account";
```

Then:
- Update OPA policy: add omega's principal → allow `tenant_omega.*`, deny `analytics.*`
- Add omega resource-group entry in `etc/resource-groups.json`; reload config
- Add omega to your CI isolation test suite (see below)

### Add a CI Test for Isolation

Every new tenant onboarding should run this before going to production:

```sql
-- As omega-service-account:

-- Must succeed (own data only)
SELECT count(*) FROM tenant_omega.events;

-- Must fail with Access Denied
SELECT count(*) FROM iceberg.analytics.events;

-- Must fail with Access Denied
SELECT count(*) FROM tenant_acme.events;

-- Must fail with Access Denied
SELECT * FROM system.runtime.queries;

-- Must fail with Access Denied
SELECT * FROM iceberg.analytics."events$partitions";
```

If all five tests produce the expected results, the tenant's isolation is correct. A bug in the view's WHERE clause gets caught before production data is exposed.

### Why This Solves Your Original Problem

A developer writes:
```sql
-- Authenticated as acme-service-account, forgets WHERE tenant_id = 'acme'
SELECT count(*) FROM iceberg.analytics.events;
```

What happens: Trino consults OPA → OPA denies (tenant principals can't access base tables) → **Access Denied**, before any data is read. The enforcement is at the query engine, not the application layer.

With the current shared service account, a forgotten WHERE clause returns every tenant's data. With per-tenant service accounts + views + OPA, the same forgotten WHERE clause returns an error.
