# Iter74 Q1 — Answer

**Question**: We have a shared Iceberg table with `tenant_id` column and want to give each tenant's users access via Trino with per-tenant views filtering on `tenant_id`. How does Trino enforce users can only query through the view? What is the SECURITY INVOKER vs SECURITY DEFINER distinction and which is safe? Can a "wrong" view allow cross-tenant data leakage?

---

## Answer

You're thinking about this correctly — views plus access control are the right approach. Let me address your three concerns directly.

### (a) How Trino enforces users can only query through the view

Trino does **not** automatically prevent a user from querying the base table just because you created a view. You must explicitly enforce it using **system access control** (OPA in your production setup).

The three-piece setup:
1. Create the base table (`analytics.events`) — admin access only
2. Create per-tenant views (e.g., `tenant_acme.events` with `WHERE tenant_id = 'acme'`)
3. Configure OPA to deny direct `SELECT` on the base table for tenant principals, while allowing `SELECT` on their view

When Acme's service account runs `SELECT * FROM analytics.events` directly, OPA rejects it at the analysis phase — before any data is read from MinIO — with `Access Denied`. When they query `SELECT * FROM tenant_acme.events`, it succeeds.

**The denial happens at the Trino coordinator**, before execution touches MinIO. Views alone are not enough — the OPA policy must exist.

### (b) SECURITY INVOKER vs SECURITY DEFINER — the critical distinction

**Default behavior (SECURITY DEFINER):** When you create a view without specifying, Trino uses `SECURITY DEFINER` — the view runs with the **view owner's** table grants. If an admin creates the view and the admin has `SELECT` on all tenants' data, the view executes with those broad grants. The `WHERE tenant_id = 'acme'` filter works when correct, but any bug in the view filter (typo, malformed join) could expose all tenants' data because the view owner's access is what actually reads the base table.

**Safe behavior (SECURITY INVOKER):** You **must** create all multi-tenant views with `SECURITY INVOKER`. This tells Trino to run the view with the **querying user's** grants. Since the tenant's role doesn't have `SELECT` on the base table (OPA denies it), the view becomes a second line of defense — not the only one.

**The correct pattern:**

```sql
CREATE VIEW tenant_acme.events
SECURITY INVOKER
AS
  SELECT event_id, user_id, event_type, event_ts, payload
  FROM analytics.events
  WHERE tenant_id = 'acme';
```

Grant the tenant role access to the view only:
```sql
GRANT SELECT ON tenant_acme.events TO ROLE acme_role;
```

### (c) How a "wrong" view can leak cross-tenant data

**Mistake 1: Creating with SECURITY DEFINER (the default)**

If the view owner is an admin with broad grants, a bug in the filter (typo in `tenant_id`, missing `AND`, broken join to a lookup table) means the view owner's access to all tenants' data is what's actually being used. Under `SECURITY INVOKER`, the same bug can't expose another tenant's data because the tenant's role can't access the base table to begin with.

**Mistake 2: Granting the tenant role SELECT on the base table instead of the view**

```sql
-- WRONG — tenant can now bypass the view entirely
GRANT SELECT ON analytics.events TO ROLE acme_role;

-- CORRECT — only the view
GRANT SELECT ON tenant_acme.events TO ROLE acme_role;
```

With base-table access, the tenant runs `SELECT * FROM analytics.events` and reads every tenant's data. The view filter is completely irrelevant.

**Mistake 3: Not revoking the user principal's implicit access**

After creating the role, you must also explicitly revoke the user principal's base-table access:

```sql
REVOKE ALL PRIVILEGES ON analytics.events FROM USER "acme-service-account";
```

Note this is `REVOKE FROM USER`, not `REVOKE FROM ROLE`. Under Trino's default access control, the user principal already had implicit access to every table before the role was created. Revoking from the role alone doesn't cover this.

**Mistake 4: Forgetting to deny the `system` catalog and Iceberg metadata tables**

Even with perfect view isolation, tenant accounts can query:

```sql
-- Sees full SQL text + principal for every query on the cluster
SELECT query, user FROM system.runtime.queries;

-- Leaks your entire customer roster and their data volumes
SELECT * FROM iceberg.analytics."events$partitions";
```

Your OPA policy **must** deny the entire `system` catalog and all `$`-suffix metadata tables to tenant principals — separately from the base-table denial.

### What you actually need to configure

| Requirement | Why |
|---|---|
| Views created with `SECURITY INVOKER` | View executes with caller's grants, not owner's broad grants |
| OPA denies base-table `SELECT` for tenant principals | Prevents bypassing the view |
| `REVOKE` user principal's base-table access | Covers implicit access before role creation |
| Views for admin roles too — never base-table grants | Admin-scoped view still filters on `tenant_id` |
| OPA denies `system` catalog and `$` metadata tables | Prevents query-text leak and customer roster leak |
| CI test: `SELECT * FROM analytics.events` as each tenant role → `Access Denied` | Catches regressions |

The view + role + OPA combination is exactly right for your scale. Just make sure all three pieces are configured — views alone are not enough.
