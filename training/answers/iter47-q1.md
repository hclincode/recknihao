# Iter47 Q1 Answer — Multi-tenant REVOKE USER vs ROLE

**Question**: We set up Trino isolation for one of our enterprise tenants — created a role called `acme_role`, ran `GRANT ROLE acme_role TO USER "acme-service-account"`, granted the role SELECT on our per-tenant view, and then ran `REVOKE ALL ON analytics.events FROM ROLE acme_role` to block base-table access. But when I test with the acme service account it can still run `SELECT COUNT(*) FROM analytics.events` and get a number that includes other tenants' rows. I thought the REVOKE would have locked them out of the base table. What did we do wrong?

---

## The problem

You ran `REVOKE ALL ON analytics.events FROM ROLE acme_role`, expecting to block base-table access. But the `acme_role` never had base-table access in the first place — so revoking from it did nothing. Your user principal still has implicit default access under Trino's default "allow-all" policy.

## Why the REVOKE was a no-op

Under Trino's default access control, all user principals start with implicit read access to all tables. This default access lives on the **USER principal**, not on any role. When you create a role and assign it to a user, the role has zero privileges — it doesn't inherit anything from the default allow-all. The role only has what you explicitly GRANT to it.

When you ran `REVOKE ALL ON analytics.events FROM ROLE acme_role`, Trino said "okay, acme_role no longer has base-table access" — but acme_role never had base-table access to begin with. The revoke was a no-op. The user's default access remained untouched.

## The fix: revoke from the USER principal

```sql
REVOKE ALL ON analytics.events FROM USER "acme-service-account"
```

This removes the default access that predates the role, leaving the service account with only what the role explicitly grants (SELECT on the `tenant_acme.events` view, which has the tenant filter baked in).

## The correct four-step isolation sequence

Your isolation setup needs all four pieces:

1. **Create the view** with the tenant filter baked in:
   ```sql
   CREATE VIEW tenant_acme.events AS
   SELECT * FROM analytics.events WHERE tenant_id = 'acme';
   ```

2. **Create the role** and assign it to the user:
   ```sql
   CREATE ROLE acme_role;
   GRANT ROLE acme_role TO USER "acme-service-account";
   ```

3. **Grant SELECT on the view to the role**:
   ```sql
   GRANT SELECT ON tenant_acme.events TO ROLE acme_role;
   ```

4. **Revoke base-table access from the USER PRINCIPAL** (not the role):
   ```sql
   REVOKE ALL ON analytics.events FROM USER "acme-service-account";
   ```

You completed steps 1–3 but skipped step 4. That is the leak.

## Test the fix

Connect as `acme-service-account` and run:
```sql
-- This should now fail with Access Denied
SELECT COUNT(*) FROM analytics.events;

-- This should still work (returns only acme's rows)
SELECT COUNT(*) FROM tenant_acme.events;
```

## One important note for your production environment

Your production environment uses **OPA (Open Policy Agent)** as the authorization backend. The SQL-level REVOKE handles the Trino access-control layer, but the OPA policy must also explicitly deny base-table SELECT for tenant principals. SQL REVOKE alone is not enough in an OPA-configured deployment — check with your platform team that the OPA configuration is in place.
