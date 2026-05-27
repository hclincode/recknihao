# Iter97 Q1 — Answer

**Question**: We're building multi-tenant analytics where each customer should only see their own data. Someone on my team suggested we create a database view per tenant in Trino that filters rows down to just that tenant's records, and then give each tenant's service account permission only to query their own view — not the underlying table directly. That sounds reasonable to me, but I'm not sure how to actually set that up, or whether there's a way for a tenant to somehow bypass the view and hit the raw table anyway. How does this pattern actually work in practice, and what are the real failure modes I should be worried about?

---

## Answer

## How the view + access control pattern works

The core idea: a view that hard-codes the tenant filter, combined with OPA denying base-table access, creates a security boundary the tenant cannot bypass. Here's the concrete setup:

### Step 1: Create the base table (admin-only)

```sql
CREATE TABLE analytics.events (
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

The base table holds all tenants' data. Only your internal data team queries it directly.

### Step 2: Create a per-tenant view with the filter baked in

```sql
CREATE VIEW tenant_acme.events AS
  SELECT event_id, user_id, event_type, event_ts
  FROM analytics.events
  WHERE tenant_id = 'acme';
```

The WHERE clause is not a UI convenience — it's the security boundary. The view runs under the view owner's grants (SECURITY DEFINER mode — Trino's default). Acme's account only needs SELECT on the view; they never get a direct base-table grant.

### Step 3: Create a role and grant view access

```sql
CREATE ROLE acme_role;
GRANT ROLE acme_role TO USER "acme-service-account";
GRANT SELECT ON tenant_acme.events TO ROLE acme_role;
```

### Step 4: Explicitly revoke base-table access — this step is not optional

```sql
REVOKE ALL PRIVILEGES ON analytics.events FROM USER "acme-service-account";
```

Trino's default authorization is "allow-all" for authenticated users — before any role was created, Acme's account already had implicit access to every table. Creating a role with a view grant does **not** remove that pre-existing access. Without this REVOKE, Acme can bypass the view entirely:

```sql
SELECT * FROM analytics.events;  -- Silently succeeds. Leaks all tenants' data.
```

### Step 5: OPA enforces the deny at query time

Your OPA policy must explicitly deny base-table SELECT for tenant principals. The specific rules live in your external governance document, but conceptually: "deny SELECT on catalog:iceberg schema:analytics table:* unless principal is in admin/data-team whitelist." OPA runs on every query, independent of SQL grants — it's the backstop that holds even if grants drift over time.

## Why this pattern is correct

- **Single table to maintain**: one shared events table, one view per tenant, not 80 copies of the schema.
- **Query performance**: `WHERE tenant_id = 'acme'` is pushed down to Iceberg's partition pruning — Acme's queries only read Acme's Parquet files.
- **SECURITY DEFINER** (Trino default): the view body runs with the view owner's grants, not the tenant's. Acme never needs direct base-table access to execute the view.
- **Defense in depth**: the view's WHERE clause is layer one; OPA's deny rule is layer two.

## Real failure modes

### Failure mode 1: Forgetting the REVOKE

If you create the role and grant the view but skip `REVOKE ALL PRIVILEGES ON analytics.events FROM USER "acme-service-account"`, Acme keeps its pre-existing implicit allow-all access. The view is useless as a security boundary. **Add a CI test** that authenticates as the tenant account and confirms `SELECT * FROM analytics.events` returns Access Denied.

### Failure mode 2: OPA missing the base-table deny

OPA's explicit deny is the backstop. If someone later grants the tenant principal direct table access for debugging, or a provisioning script re-grants permissions, the REVOKE becomes stale. OPA running on every query is what keeps the boundary durable over time.

### Failure mode 3: Tenant-admin roles that get base-table access

A common mistake:

```sql
-- WRONG — grants access to ALL tenants' data
GRANT SELECT ON analytics.events TO ROLE acme_admin_role;
```

The base table has no tenant filter — granting it to any role exposes every customer. The correct pattern applies the same view discipline to admin roles:

```sql
-- CORRECT
CREATE VIEW tenant_acme_admin.events AS
  SELECT * FROM analytics.events WHERE tenant_id = 'acme';

GRANT SELECT ON tenant_acme_admin.events TO ROLE acme_admin_role;
REVOKE ALL PRIVILEGES ON analytics.events FROM ROLE acme_admin_role;
```

### Failure mode 4: Iceberg metadata table leaks

Even with base-table access denied, Acme can query Iceberg metadata tables to see your entire customer roster and event volumes per tenant:

```sql
SELECT * FROM iceberg.analytics."events$partitions";  -- leaks all tenant IDs and row counts
```

Your OPA policy must deny any table name containing `$` for tenant principals.

### Failure mode 5: `system.runtime.queries` leaks

By default, any authenticated user can run `SELECT * FROM system.runtime.queries` and see every other tenant's query SQL — including WHERE clause values with customer IDs, emails, and business logic. OPA must deny the entire `system` catalog to tenant principals.

## CI test to verify

Authenticate as the tenant account and run two queries:

```sql
-- Should succeed (returns row count)
SELECT COUNT(*) FROM tenant_acme.events;

-- Should fail with Access Denied
SELECT COUNT(*) FROM analytics.events;
```

Also test metadata and system denies:

```sql
SELECT * FROM iceberg.analytics."events$partitions";  -- should fail
SELECT * FROM system.runtime.queries;                 -- should fail
```

If any of these return data instead of Access Denied, treat it as a P0 security incident and fix the OPA policy immediately.

## Setup checklist for each new tenant

1. CREATE VIEW tenant\_\{id\}.events with hard-coded `WHERE tenant_id = '{id}'`
2. CREATE ROLE tenant\_\{id\}\_role
3. GRANT SELECT ON tenant\_\{id\}.events TO ROLE tenant\_\{id\}\_role
4. GRANT ROLE tenant\_\{id\}\_role TO USER "{id}-service-account"
5. REVOKE ALL PRIVILEGES ON analytics.events FROM USER "{id}-service-account"
6. Run CI isolation tests before marking provisioning complete
