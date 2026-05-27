# Answer to Q1: Multi-Tenant Isolation with Trino Views + OPA (Iter 308)

## Why "Trust the Code" Fails

Relying on every query to include `WHERE tenant_id = ?` means any bug, SQL injection, or forgotten filter leaks every customer's data at once. Moving to Trino is the opportunity to shift that enforcement from the application to the query engine.

## The Architecture: Shared Table + Per-Tenant Views + OPA

1. **One base table** (`iceberg.analytics.events`) partitioned by `(day(occurred_at), tenant_id)`, holding all customers' data
2. **One filtered view per tenant** with the tenant ID hard-coded in the WHERE clause
3. **Access control** granting customers SELECT only on their view, never on the base table
4. **OPA (Open Policy Agent)** denying any direct base-table access from tenant principals

## Why Views Stop SQL Injection and Custom Queries

A Trino view is a saved SELECT statement that executes with **SECURITY DEFINER semantics** (Trino's default). This means:
- The view body executes with the **view owner's privileges** (a privileged service account), not the caller's
- The caller (your customer) only needs SELECT on the view — they never need SELECT on `analytics.events`
- The WHERE clause in the view is immutable: a customer running `SELECT * FROM tenant_acme.events WHERE 1=1` gets Trino executing `SELECT * FROM analytics.events WHERE tenant_id = 'acme' AND 1=1` — they cannot remove the first condition

Without OPA, a customer could bypass the view by querying the base table directly. OPA closes that back door.

## Production DDL — Onboarding Tenant "acme"

```sql
-- Step 1: Create the base table (admin-only access)
CREATE TABLE iceberg.analytics.events (
  event_id    BIGINT,
  tenant_id   VARCHAR,
  user_id     VARCHAR,
  event_type  VARCHAR,
  occurred_at TIMESTAMP(6),
  payload     VARCHAR
)
WITH (partitioning = ARRAY['day(occurred_at)', 'tenant_id'], format = 'PARQUET');

-- Step 2: Create per-tenant schema
CREATE SCHEMA IF NOT EXISTS tenant_acme;

-- Step 3: Create the tenant-scoped view with WHERE clause baked in
-- (SECURITY DEFINER is Trino's default — view runs with owner's grants)
CREATE VIEW tenant_acme.events AS
  SELECT event_id, user_id, event_type, occurred_at, payload
  FROM iceberg.analytics.events
  WHERE tenant_id = 'acme';

-- Step 4: Create a role for this tenant
CREATE ROLE acme_role;

-- Step 5: Assign the role to the tenant's service account
GRANT ROLE acme_role TO USER "acme-service-account";

-- Step 6: Grant SELECT on the VIEW ONLY — not the base table
GRANT SELECT ON tenant_acme.events TO ROLE acme_role;
```

At this point:
- `acme-service-account` can run `SELECT * FROM tenant_acme.events` and gets only Acme rows ✓
- `acme-service-account` cannot run `SELECT * FROM iceberg.analytics.events` — OPA denies it ✓
- `beta-service-account` cannot run `SELECT * FROM tenant_acme.events` — they don't have `acme_role` ✓

## How OPA Integrates

When a query arrives, Trino calls OPA for every table/view reference during the analysis phase: "Can `acme-service-account` SELECT from `analytics.events`?" OPA evaluates the Rego policy and returns `allow: false` for tenant principals trying to access the base table — **before any data is read from MinIO**.

The view + role grants are defense-in-depth if OPA is misconfigured. OPA is the gate that locks the back door.

## What Customers Can and Cannot Do

**Customer Acme runs their own SQL:**
```sql
SELECT event_type, COUNT(*) FROM tenant_acme.events
WHERE occurred_at >= TIMESTAMP '2026-05-01 00:00:00'
GROUP BY event_type;

-- Trino executes (view definition inlined):
SELECT event_type, COUNT(*) FROM iceberg.analytics.events
WHERE tenant_id = 'acme'         -- immutable, baked in
  AND occurred_at >= TIMESTAMP '2026-05-01 00:00:00'
GROUP BY event_type;
-- Result: only Acme events ✓
```

**Customer Beta tries to access Acme's view:**
```sql
SELECT * FROM tenant_acme.events;
-- Access Denied: 'beta-service-account' does not have permission to SELECT FROM tenant_acme.events
```

**Customer Beta tries the base table:**
```sql
SELECT * FROM iceberg.analytics.events;
-- Access Denied: OPA denies tenant principals base-table access
```

**UNION ALL bypass attempt:**
```sql
SELECT * FROM tenant_acme.events
UNION ALL
SELECT * FROM iceberg.analytics.events;
-- Access Denied on the second SELECT — OPA rejects it
```

## Additional Leaks OPA Must Block

The view + role structure prevents **data row leaks**, but OPA must also deny:
- `system.runtime.queries` — tenant could see other tenants' query metadata
- `iceberg.analytics."events$files"` and `"events$partitions"` — Iceberg metadata tables reveal data volumes per partition

OPA policy should grant tenant principals access only to their own `tenant_<id>.*` schema, and nothing else.

## Verification Test Cases

Add these to your CI:

```sql
-- As acme-service-account:
SELECT DISTINCT tenant_id FROM tenant_acme.events;
-- Expected: exactly one row, value = 'acme'

SELECT * FROM iceberg.analytics.events LIMIT 1;
-- Expected: Access Denied

-- As beta-service-account:
SELECT * FROM tenant_acme.events LIMIT 1;
-- Expected: Access Denied

-- As admin:
SELECT COUNT(DISTINCT tenant_id) FROM iceberg.analytics.events;
-- Expected: N (total tenant count — admin sees everything)
```

## Operational Notes

- **Schema changes:** If you add a column to `analytics.events`, existing views may be stale. After `ALTER TABLE`, verify `SHOW CREATE VIEW tenant_acme.events` still resolves correctly. Automate this check in your schema migration pipeline.
- **OPA policy propagation:** OPA bundles poll on a schedule (30s–5min). New tenant grants take effect on the next OPA bundle refresh. For immediate enforcement, the view grant still protects (customer won't have SELECT on the new view until you explicitly grant it).
- **Scaling to many tenants:** At 80+ tenants, generating views and grants programmatically (via Terraform or a provisioning script) is necessary. Template the DDL above and run it per-tenant during onboarding.
