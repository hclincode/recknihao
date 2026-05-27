# Iter48 Q1 Answer — $partitions metadata table data leak

**Question**: We partition our Iceberg `analytics.events` table by both `day(occurred_at)` and `tenant_id`. Our per-tenant service accounts can only query through a view like `tenant_acme.events` that filters to `WHERE tenant_id = 'acme'`. But one of our enterprise customers just emailed us saying they ran `SELECT * FROM iceberg.analytics."events$partitions"` and got back a table listing every tenant in our system — tenant IDs, partition-level row counts, and file counts per tenant per day. Is this a real data leak? What do they have access to and how do we stop it?

---

Yes, this is a real data leak — and one of the most dangerous kinds: metadata exposure. Your customer saw your entire customer roster and their activity levels.

## What the customer discovered

Iceberg tables expose built-in **metadata views** that show internal table statistics. When you run `SELECT * FROM iceberg.analytics."events$partitions"`, you're querying Iceberg's `$partitions` metadata view. It returns, for each partition:
- The partition key values — in your case, `tenant_id` and `day(occurred_at)`
- Row counts per partition (`record_count`)
- File counts per partition
- Min/max value ranges per column

Your per-tenant view (`tenant_acme.events`) filters the *data rows* correctly. But it does **not** filter the metadata views that derive from the base table. The metadata tables query the table's metadata layer, which knows nothing about the view's row-level filter. If a tenant can reference `iceberg.analytics."events$partitions"` directly, they bypass the view's WHERE clause entirely.

## What data leaked

Your customer can now see:
1. **Every tenant ID in your system** — your complete customer roster, exposed as partition key values
2. **Activity patterns** — row counts per tenant per day reveal which customers are active, how much, and when
3. **Data volume distribution** — file counts and sizes show which tenants have large amounts of data

This is not row-level data (they cannot read other tenants' events), but it is **structural intelligence** about your customer base.

## The fix — two layers

**Layer 1: OPA policy must explicitly deny metadata table access.**

In your production environment, the OPA governance document should contain rules that deny tenant principals from querying Iceberg metadata tables. The conceptual rule: block any query from a tenant principal that targets the `iceberg.analytics` schema directly. Only allow access via tenant-scoped views in `iceberg.tenant_acme.*`, etc. The OPA Rego specifics belong in your governance document — specific policy rules should not be written here; check with your platform team.

**Layer 2: SQL-level REVOKE (defense in depth).**

Revoke any lingering table-level or metadata-table grants from both the role and the user principal:

```sql
-- Revoke from the ROLE (if any grants were given to the role)
REVOKE ALL ON iceberg.analytics.events FROM ROLE acme_role;

-- CRITICAL: Also revoke from the USER PRINCIPAL (default allow-all lives on the USER, not the role)
REVOKE ALL ON iceberg.analytics.events FROM USER "acme-service-account";
```

Note: Trino's default allow-all access control gives USER PRINCIPALS implicit base-table access. Revoking only from the role is a no-op if the role never had the grant. You must revoke from the USER PRINCIPAL to close the back door.

## Verify and prevent regression

Test that the fix worked:
```sql
-- Connect as acme-service-account and run — should fail with Access Denied
SELECT * FROM iceberg.analytics."events$partitions" LIMIT 1;

-- This should still work
SELECT COUNT(*) FROM iceberg.tenant_acme.events;
```

Add this as a CI test so any future access control misconfiguration is caught before production.

## Other metadata tables to block

The same leak path applies to all Iceberg metadata tables. Block them all for tenant principals:
- `"events$partitions"` — partition stats including tenant IDs and row counts (what your customer found)
- `"events$files"` — individual file paths, sizes, record counts
- `"events$snapshots"` — table history including operation types and timestamps
- `"events$history"` — snapshot lineage

Treat all `$`-suffix metadata tables as sensitive and deny them in OPA for non-admin principals.

## Immediate action

Treat this as a security incident:
1. **Fix the OPA policy** to deny the `iceberg.analytics` catalog to tenant principals
2. **Run the SQL REVOKE commands** above
3. **Audit query logs** for other tenant principals that queried `$partitions` or the `analytics` schema directly
4. **Notify affected customers** appropriately per your security disclosure policy
