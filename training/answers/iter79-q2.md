# Iter79 Q2 — Answer

**Question**: With shared Iceberg table + tenant_id, what is the complete operational checklist when a new customer signs up? How do you set up data isolation and prevent noisy-neighbor query problems?

---

## Answer

With a shared Iceberg table, onboarding a new tenant requires no changes at the Iceberg or MinIO layer — the table already exists and automatically partitions new data by `tenant_id`. All the provisioning work is at the Trino layer. Here's the complete checklist.

### What you don't need to do

No new Iceberg tables, no new MinIO buckets, no schema creation. When Spark writes rows with the new tenant's `tenant_id`, they land in the right partition automatically.

### The Trino provisioning checklist

Run these steps in order when a new tenant signs up. Wrap each in idempotent error handling (treat "already exists" as success, not failure) so the script is safe to re-run:

**Step 1: Create a Trino role**

```sql
CREATE ROLE acme_role;
```

**Step 2: Assign the role to the tenant's service account**

```sql
GRANT ROLE acme_role TO USER "acme-service-account";
```

A role with no assigned user is a silent no-op — this step is essential.

**Step 3: Create tenant-scoped views (one per table)**

```sql
CREATE VIEW tenant_acme.events AS
  SELECT event_id, user_id, event_type, occurred_at, payload
  FROM analytics.events
  WHERE tenant_id = 'acme';
```

Repeat for every table the tenant needs access to (`orders`, `users`, `sessions`, etc.). The `WHERE tenant_id = 'acme'` filter is hard-coded — even if application code forgets to filter, the view enforces it.

**Step 4: Grant the role SELECT on the views**

```sql
GRANT SELECT ON tenant_acme.events TO ROLE acme_role;
```

Tenants get read access only to their scoped views, never to the shared base table.

**Step 5: Revoke base-table access from the user principal**

```sql
REVOKE ALL PRIVILEGES ON analytics.events FROM USER "acme-service-account";
```

By default, Trino allows all authenticated users to read everything. This REVOKE closes the back door — without it, a tenant can bypass the view entirely and query the base table directly. Must be applied to the user principal (not just the role).

**Step 6: Add the tenant to resource groups (noisy neighbor prevention)**

Add a resource-group entry to cap this tenant's cluster share:

```json
{
  "name": "tenant_acme",
  "softMemoryLimit": "10%",
  "hardConcurrencyLimit": 5,
  "maxQueued": 50
}
```

With a selector mapping `acme-service-account` to `global.tenant_acme`. This limits Acme to 5 concurrent queries and 10% of cluster memory — if they exceed that, queries queue rather than starving other tenants.

For frequent tenant onboarding (15–20/month), use **DB-backed resource groups** (`resource-groups.configuration-manager=db`) — this hot-reloads every ~1 second and requires no coordinator restart. File-based resource groups require a coordinator restart for each change.

**Step 7: Run a verification test**

```sql
-- Should succeed:
SELECT COUNT(*) FROM tenant_acme.events;  -- as acme-service-account

-- Should fail with "Access Denied":
SELECT COUNT(*) FROM analytics.events;   -- as acme-service-account
```

Include this in your CI pipeline to catch isolation regressions before tenants do.

### How isolation is enforced (defense in depth)

Three independent layers protect each tenant:

1. **Trino views** — hard-code `WHERE tenant_id = 'acme'`; app code can't bypass
2. **Role grants** — `acme_role` has SELECT on views only, not the base table
3. **OPA policy** (your production access control layer) — explicitly denies `analytics.events` to tenant principals at the system level

All three must agree before a query can read base-table data. A bug in any one layer is caught by the others.

### Immediate noisy-neighbor relief

If a tenant is starving others right now, kill the offending query immediately — don't wait for config changes:

```sql
SELECT query_id, user, state, elapsed_time
FROM system.runtime.queries
WHERE state = 'RUNNING'
ORDER BY elapsed_time DESC;

CALL system.runtime.kill_query(
  query_id => '20260525_...',
  message  => 'Noisy neighbor throttling'
);
```

Deploy resource-group limits afterward to prevent recurrence.

### Summary

| Step | What it does | Iceberg/MinIO change? |
|---|---|---|
| No table/schema creation needed | New tenant data lands by `tenant_id` partition automatically | None |
| `CREATE ROLE` + `GRANT ROLE TO USER` | Binds permissions to the service account | None |
| `CREATE VIEW` with `WHERE tenant_id` | Enforces row isolation at query time | None |
| `GRANT SELECT ON views` + `REVOKE` on base | Blocks direct base-table access | None |
| Resource group entry | Prevents noisy-neighbor query starvation | None |
| Verification test | Confirms isolation before go-live | None |
