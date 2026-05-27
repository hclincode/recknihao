# Iter264 Q2 — Multi-Tenant Isolation in Trino: Beyond Application-Level WHERE Clauses

## Answer

**Your concern is well-founded — application-level filters alone are not sufficient.** One forgotten WHERE clause, a junior developer's mistake, or a refactoring bug can expose every customer's data. You need Trino itself to enforce the isolation, not just the application.

### What's Wrong with Application-Only Filtering

You're currently using application-level filtering as your only defensive mechanism:

```
Customer query → App adds WHERE customer_id = ? → Trino → Data
                 ↑ Only defensive mechanism
```

If the app forgets the WHERE clause (or a SQL injection bypasses it), Trino reads all the data and returns it. One missed WHERE clause in a dashboard feature or ad-hoc query is enough to expose Customer B's data to Customer A. This is a common real-world failure mode, not a theoretical concern.

### The Correct Approach: Trino Views + OPA Access Control

The production pattern is **tenant-scoped Trino views plus OPA policy enforcement**. It provides three independent defensive layers.

#### Layer 1: Tenant-scoped views with hard-coded WHERE clauses

Create a view per tenant that bakes the tenant filter into the view definition:

```sql
CREATE SCHEMA IF NOT EXISTS tenant_acme;

CREATE VIEW tenant_acme.events AS
  SELECT event_id, user_id, event_type, event_ts, payload
  FROM iceberg.analytics.events
  WHERE tenant_id = 'acme';

CREATE VIEW tenant_acme.accounts AS
  SELECT account_id, name, plan_tier
  FROM app_pg.public.accounts
  WHERE tenant_id = 'acme';
```

Customers query `tenant_acme.events` — not the base table. The WHERE `tenant_id = 'acme'` is baked into the view and cannot be bypassed by the query itself.

#### Layer 2: OPA denies direct base-table access

Your production stack uses OPA (Open Policy Agent) for Trino authorization. Configure OPA to:
- **Allow** tenant principals to SELECT on their own tenant-scoped view
- **Deny** tenant principals any direct access to the base tables (`iceberg.analytics.events`, `app_pg.public.accounts`)
- **Deny** access to Iceberg metadata tables (which would leak information about other tenants' data volume)

The execution flow with OPA:

```
Customer A queries: SELECT count(*) FROM tenant_acme.events
→ Trino routes to OPA: "Can this principal SELECT tenant_acme.events?" → Allow
→ View expands to: SELECT ... FROM iceberg.analytics.events WHERE tenant_id = 'acme'
→ Returns only Acme rows ✓

Customer A (or a bug) queries: SELECT count(*) FROM iceberg.analytics.events
→ Trino routes to OPA: "Can this principal SELECT iceberg.analytics.events?" → Deny
→ Access Denied before any data is read ✓
```

This means even if the application forgets the WHERE clause, OPA blocks direct base-table access before any data is touched.

#### Layer 3: Metadata access denial

OPA should also deny access to Iceberg system tables (`events$snapshots`, `events$files`, etc.) — these can leak information about other tenants' data volume and file layout even without row-level access.

### Defense-in-Depth Comparison

| Approach | Failure mode |
|---|---|
| **App-only WHERE clause** | Developer forgets → leaks all data |
| **Trino views only** | View definition bug → still leaks |
| **OPA only (no view)** | Row filter misconfiguration → still leaks |
| **Views + OPA (recommended)** | Both must fail independently → defense-in-depth |

### Important Note on Your Production Stack

Since you're on Trino 467 with OPA authorization:
- **OPA is the actual enforcement mechanism** — SQL `GRANT`/`REVOKE` statements are ignored. When you need to adjust permissions, update your OPA policy bundle, not SQL statements.
- Views are standard SQL `CREATE VIEW`. Trino's default view security mode is `SECURITY DEFINER`, which is correct here — the view runs with the permissions of its creator, not the querying customer.
- The specific OPA Rego rules for tenant-scoped access control should be set up by your platform team.

### What NOT to Do

- **Don't rely solely on the application** to add WHERE clauses — this is what you're currently doing, and it's fragile.
- **Don't give customers direct base-table access** and rely on runtime filters — the defense is too thin.
- **Don't mix OPA with SQL GRANT/REVOKE** — on your stack, only OPA counts.

### Implementation Steps

1. **Create tenant-scoped views** covering every table customers can query (both Iceberg and Postgres sides of the join)
2. **Update OPA policies** to deny customer principals direct access to base tables and metadata
3. **Grant customers access only to their views** (via OPA, not SQL GRANT)
4. **Integration test**: connect as a customer principal and verify:
   - `SELECT FROM tenant_acme.events` works
   - `SELECT FROM iceberg.analytics.events` (without view) → Access Denied
   - `SELECT FROM iceberg.analytics."events$snapshots"` → Access Denied

Shifting isolation from "remember to add WHERE every time" to "OPA enforces it on every query" is the right long-term architecture for multi-tenant SaaS on Trino.
