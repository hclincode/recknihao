# Iter49 Q1 Answer — current_user in multi-tenant Trino views

**Question**: We have about 50 tenants sharing one Trino cluster. Right now we create a separate view per tenant with a hardcoded WHERE tenant_id filter. Someone suggested we use `CREATE VIEW analytics.my_events AS SELECT * FROM analytics.events WHERE tenant_id = current_user`. Would this work? Is it safe? Trade-offs?

---

## The short answer

Using `current_user` to dynamically filter by tenant works technically, but it trades a hard-to-debug safety problem (one bug affects all 50 tenants) for your current one-at-a-time maintenance burden. At 50 tenants, stick with per-tenant views. The trade-off becomes compelling around 150–200 tenants.

## How `current_user` actually works

Trino does support `current_user` in view definitions — it returns the authenticated principal (the username from the JWT token) executing the query. So `WHERE tenant_id = current_user` correctly filters to the querying user's tenant.

But there are two critical requirements:

**Requirement 1: your `tenant_id` column values must exactly match your Trino usernames.** If `tenant_id = 'acme'` but the JWT username is `acme-service-account`, the view returns zero rows silently with no error. If you go this route, you need a lookup table:

```sql
CREATE VIEW analytics.my_events
SECURITY INVOKER
AS
  SELECT e.*
  FROM analytics.events e
  JOIN config.user_tenant_map m
    ON e.tenant_id = m.tenant_id
  WHERE m.username = current_user;
```

**Requirement 2: the view MUST be created with `SECURITY INVOKER`.** The default is `SECURITY DEFINER`, which is unsafe for multi-tenant use. With `SECURITY DEFINER`, the view runs with the view owner's grants — if the owner has SELECT on the base table, the filter is the only isolation layer. With `SECURITY INVOKER`, the view runs with the querying user's grants — even if the filter is misconfigured, the user can't read data they don't have a table grant for.

## The trade-off: blast radius

With per-tenant views (your current approach), a bug in one tenant's view affects only that tenant. With a shared `current_user` view, a bug in the lookup table or the view definition affects all 50 tenants simultaneously. This is the core trade-off.

**Per-tenant views win at your scale because:**
- A provisioning script typo breaks one tenant, not all of them
- Audit is simple: `tenant_acme.events` in the query log immediately tells you which tenant ran what
- Schema changes (adding a column) only require updating the affected view(s), not a central mapping table
- No single point of failure (`user_tenant_map` is a P0 failure surface for all tenants)

**Shared `current_user` view becomes worth it at 150–200 tenants because:**
- Adding a column requires DDL migrations across 150+ schemas — a multi-hour operation
- Hive Metastore list operations slow down significantly at 500+ schemas
- The provisioning script complexity grows linearly with tenant count

## You still need the base-table REVOKE

Whether you use per-tenant views or a shared `current_user` view, you must still revoke base-table access from the USER PRINCIPAL:

```sql
REVOKE ALL ON analytics.events FROM USER "acme-service-account";
```

This is because Trino's default allow-all access control gives USER PRINCIPALS implicit base-table access. Without this REVOKE, tenants can bypass the view entirely and query `SELECT * FROM analytics.events` directly. The view filter (whether hardcoded or `current_user`) is not the only isolation layer — you need both.

## Your best path forward at 50 tenants

1. **Keep the per-tenant view approach** — it's correct and scales to ~100 tenants without pain
2. **Automate provisioning**: a single script that reads a list of tenant IDs and generates `CREATE VIEW + GRANT + REVOKE` statements
3. **Add CI tests**: for each tenant role, assert `SELECT COUNT(*) FROM analytics.events` fails (base table blocked) and `SELECT COUNT(*) FROM tenant_acme.events` succeeds
4. **Revisit at 150 tenants** — that's when the maintenance burden of per-tenant DDL migrations starts to justify the blast-radius risk of dynamic filtering
