# Iter60 Q1 — Answer

**Question**: We're running Trino on Kubernetes and we have about 40 paying customers hitting the same cluster. Right now we're controlling what data each customer can see with a big WHERE clause baked into every query — basically `WHERE tenant_id = ?` in our application layer before we hand the SQL off to Trino. It works but I'm nervous about it. If a developer writes a new query and forgets the tenant filter, suddenly one customer can see another customer's data. Is there a way to enforce this at the Trino level so a bad query can't accidentally leak data across tenants? I've heard something about "row-level security" but I don't know if Trino actually has that.

---

## Answer

Your concern is valid — application-layer WHERE clauses are the #1 multi-tenant data-leak vector in SaaS analytics. Trino does not have SQL-standard row-level security (no `CREATE POLICY`), but the **view + role** approach accomplishes the same goal and is actually stronger, because the filter is enforced at the query engine before any data is read.

### Why the app-layer approach is dangerous

Trino only sees the raw SQL text. It has no concept of "which customer is asking." A query without the tenant filter scans every file in the table — all 40 tenants' data — and returns it. One forgotten `WHERE tenant_id = ?` is a complete, silent data leak.

### The correct Trino approach: per-tenant views

Create one view per tenant with the `tenant_id` filter baked into the view definition. The tenant's Trino role can only SELECT from their view, not the base table.

```sql
-- Base table — only internal admins query this directly
CREATE TABLE iceberg.analytics.events (
  event_id    BIGINT,
  tenant_id   VARCHAR,
  user_id     VARCHAR,
  event_type  VARCHAR,
  event_ts    TIMESTAMP(6) WITH TIME ZONE,
  payload     VARCHAR
)
WITH (
  format = 'PARQUET',
  partitioning = ARRAY['tenant_id', 'day(event_ts)']
);

-- One view per tenant, filter baked in
CREATE VIEW iceberg.tenant_acme.events AS
  SELECT event_id, user_id, event_type, event_ts, payload
  FROM iceberg.analytics.events
  WHERE tenant_id = 'acme';

CREATE VIEW iceberg.tenant_beta.events AS
  SELECT event_id, user_id, event_type, event_ts, payload
  FROM iceberg.analytics.events
  WHERE tenant_id = 'beta';
```

### Assign roles and grant access

```sql
-- Create role for Acme
CREATE ROLE acme_role;

-- Assign to their service account
GRANT ROLE acme_role TO USER "acme-service-account";

-- Grant SELECT on their view ONLY
GRANT SELECT ON iceberg.tenant_acme.events TO ROLE acme_role;
```

### The critical step: revoke base-table access from the user

This is where most teams make a mistake:

```sql
-- WRONG — revoking from the role does nothing
-- (the role started with zero grants; revoking nothing changes nothing)
REVOKE ALL PRIVILEGES ON iceberg.analytics.events FROM ROLE acme_role;

-- CORRECT — revoke from the user principal directly
REVOKE ALL PRIVILEGES ON iceberg.analytics.events FROM USER "acme-service-account";
```

In Trino's default access control, user principals start with implicit allow-all. A role starts with zero grants. If you only manage grants at the role level and skip the user-level revoke, the tenant's service account can still query the base table directly — bypassing the view layer entirely.

### Why this beats app-layer filtering

A developer who writes `SELECT * FROM iceberg.analytics.events` as Acme's service account gets **Access Denied** from Trino before any data is read. No amount of application code mistakes can override it. The filter lives in the view definition (version-controlled SQL), not scattered across every query in every codebase.

### Verify isolation: three test queries

Run these as the tenant's service account:

```sql
-- 1. Should SUCCEED — their own view
SELECT COUNT(*) FROM iceberg.tenant_acme.events;

-- 2. Should FAIL with Access Denied — base table
SELECT COUNT(*) FROM iceberg.analytics.events;

-- 3. Should FAIL with Access Denied — another tenant's view
SELECT COUNT(*) FROM iceberg.tenant_beta.events;
```

If all three behave correctly, isolation is working.

### What about true row-level security?

Some databases (PostgreSQL, BigQuery) have `CREATE POLICY` or row access policies that attach filters at the storage layer. Trino does not have this. The per-tenant view is the idiomatic Trino equivalent — and in practice it's more transparent, since the filter is plainly visible SQL rather than a hidden policy.

### OPA as a second enforcement layer

Your production stack uses OPA (Open Policy Agent) as the Trino authorization backend. OPA policies can explicitly deny SELECT on `iceberg.analytics.events` to any principal whose username matches a tenant service account pattern, regardless of what SQL they submit. This adds defense in depth: even if the REVOKE was accidentally missed for a new tenant's account, the OPA policy still rejects the query.

Also confirm that OPA denies access to `system.runtime.queries` — the Trino query history table exposes other tenants' SQL text, which is a separate leak path that often gets overlooked.

### Resource groups for noisy-neighbor protection

In addition to data isolation, cap per-tenant query concurrency so one large customer doesn't starve the others:

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

The `"user"` field is a Java regex matching the JWT `sub` claim. This is separate from data isolation — it prevents CPU/memory contention between tenants.

### Migration path from app-layer WHERE clauses

1. Create the scoped views for all 40 tenants (can be scripted from a customer list)
2. Update your application to query `iceberg.tenant_{name}.events` instead of `iceberg.analytics.events` with a WHERE clause
3. Revoke base-table access from tenant service accounts
4. Add CI tests that verify Access Denied on the base table and other tenants' views
5. Remove the app-layer `WHERE tenant_id = ?` clause — it's now redundant (the view enforces it)

At 40 tenants, view creation is a one-time migration. When a new customer onboards, add one `CREATE VIEW` + `GRANT` to your onboarding automation.
