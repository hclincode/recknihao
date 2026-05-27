# Iter64 Q1 — Answer

**Question**: We have Trino views set up per tenant, where each view basically filters down to a specific `tenant_id`. That's fine for single tenants, but now we have a customer with multiple sub-accounts under them — think like a parent company with regional divisions. They want one dashboard that shows data across all their sub-accounts, but the sub-accounts are different tenants in our system. Someone on our team said we could build a view that figures out who the caller is and filters appropriately — like a "calling user context" kind of thing — instead of hard-coding a tenant ID in the view definition. They mentioned something about `SECURITY DEFINER` vs `SECURITY INVOKER` and said that matters for how this works in Trino. I have no idea what those terms mean. What's the difference, and which one would you use for this kind of multi-tenant parent/child scenario?

---

## Answer

These two keywords control whose database permissions Trino uses when running the view body. The difference matters enormously for multi-tenant isolation.

### SECURITY DEFINER (Trino's default)

The view runs with the **view creator's grants**, not the caller's. When you create a view without specifying, Trino defaults to `SECURITY DEFINER`. This means:

- The caller only needs SELECT on the view — they don't need direct access to the underlying tables.
- The creator's broad grants are used for all authorization checks on the underlying tables.
- `current_user` inside a DEFINER view still returns the **calling user's identity** — but the table access uses the creator's permissions.

The risk: if the creator has SELECT on all tenant data (which your admin account likely does), any caller who can SELECT the view can run it — even if a bug in the view's WHERE clause lets rows slip through. There's no storage-layer safety net. The view's logic is the only barrier.

### SECURITY INVOKER

The view runs with **the calling user's grants**. This means:

- The caller must have direct access to every table the view references (not just the view itself).
- `current_user` inside the view returns the caller's identity, and it can be used to filter results dynamically.
- If the caller's role lacks SELECT on `analytics.events`, the query fails with Access Denied — even through the view.

This is the correct mode for dynamic tenant-aware filtering because it keeps the caller's own access control in force. A misconfigured view WHERE clause can't silently leak data to a user who doesn't have underlying table access.

### Why SECURITY INVOKER + current_user is the right pattern for your scenario

For your parent/child case — a parent account with multiple regional sub-accounts — the view needs to return different data depending on who calls it. Hard-coding a single `tenant_id` doesn't work here. Instead:

1. Create a `user_tenant_map` table that maps each Trino principal to the tenant IDs they're allowed to see.
2. Create the view using `SECURITY INVOKER` so it runs with the caller's identity.
3. Use `current_user` in the view's WHERE clause to look up the allowed tenants for that caller.

```sql
-- Mapping table: which tenants can each Trino principal see?
CREATE TABLE iceberg.config.user_tenant_map (
    username    VARCHAR,   -- matches Trino principal (JWT sub claim)
    tenant_id   VARCHAR
);

-- Insert rows for your parent account's sub-accounts
INSERT INTO iceberg.config.user_tenant_map VALUES
  ('parent-corp-service-account', 'us-west'),
  ('parent-corp-service-account', 'us-east'),
  ('parent-corp-service-account', 'eu-central');

-- Create the view with SECURITY INVOKER
CREATE VIEW iceberg.tenant_parent_corp.events
SECURITY INVOKER
AS
  SELECT e.*
  FROM iceberg.analytics.events e
  JOIN iceberg.config.user_tenant_map m
    ON e.tenant_id = m.tenant_id
  WHERE m.username = current_user;
```

When the parent account's service account queries this view, `current_user` resolves to `parent-corp-service-account`, the JOIN finds their three sub-account entries, and the view returns only those tenants' events. When a single-tenant account queries a different view, their `current_user` maps to only their one tenant.

### The critical INVOKER gotcha: the caller needs access to all referenced tables

Because INVOKER runs with the caller's grants, the caller must have SELECT on:
- The base events table (`iceberg.analytics.events`)
- The user_tenant_map table (`iceberg.config.user_tenant_map`)

But your isolation model doesn't want tenants reading the base table directly. Solve this by:
- Granting SELECT on `user_tenant_map` to tenant roles (it's a config table, not sensitive event data).
- **Not** granting SELECT on `analytics.events` to tenant roles — instead, test this and confirm it raises Access Denied.

Wait — if the caller can't read `analytics.events` directly, how does the INVOKER view work? The answer: it doesn't, unless you explicitly grant the caller read on the underlying tables. This is the real trade-off. For the parent/child pattern with INVOKER, you have two options:

**Option A**: Grant tenant roles read on the base table, rely on the view's JOIN to scope results, and use OPA to block direct base-table queries (OPA can deny `SELECT * FROM analytics.events` without a corresponding view lookup). This is the approach your production OPA setup supports.

**Option B**: Stick with per-tenant hard-coded views for standard tenants, and use the INVOKER + mapping pattern only for parent accounts that explicitly need multi-tenant access. Only those parent accounts get base-table grants.

### DEFINER is simpler but riskier

If you use `SECURITY DEFINER` (the default), you don't need to grant the caller base-table access. The view creator's grants cover everything. This is simpler to set up, but:

- A bug in the view's WHERE clause (e.g., the JOIN accidentally returns all tenants for any user) silently exposes all data to any caller.
- There's no secondary enforcement. The view's logic is the only protection.

For your standard single-tenant views (hard-coded `WHERE tenant_id = 'acme'`), DEFINER is acceptable because the filter is static and trivially correct. For the dynamic parent/child view using `current_user` and a lookup table, use INVOKER — the additional layer of the caller's own grants provides defense in depth.

### Quick verification

After setting up the INVOKER view, run this as the parent account's service account:

```sql
-- Should succeed — returns combined sub-account data
SELECT COUNT(*) FROM iceberg.tenant_parent_corp.events;

-- Should fail with Access Denied — base table is off-limits
SELECT COUNT(*) FROM iceberg.analytics.events;

-- Should fail with Access Denied — other tenant's view is off-limits
SELECT COUNT(*) FROM iceberg.tenant_acme.events;
```

If the second and third queries raise Access Denied (not return zero rows), the isolation is working correctly.
