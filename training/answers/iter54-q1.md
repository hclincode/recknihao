# Iter54 Q1 — Answer

**Question**: Our security team just flagged something in our Trino setup. Apparently any authenticated user can run `SELECT * FROM system.runtime.queries` and see every query currently running on the cluster — including the full SQL text, which in our case can contain tenant-specific filter values and customer IDs. We have OPA set up as our Trino authorization backend already. How do we use OPA to block tenant users from accessing that system table while still letting our admin users query it? Is this something OPA can even enforce at the table level for system catalogs, or does it work differently there?

---

## Answer

Yes, OPA can enforce access on system catalog tables including `system.runtime.queries`. Trino routes every table access through the OPA authorization plugin before execution — this applies to system catalog reads the same as any regular table read. There is no special bypass for system catalogs.

### Why `system.runtime.queries` is a confirmed cross-tenant leak

`system.runtime.queries` shows all currently running queries on the cluster regardless of which user submitted them. Each row exposes the full SQL text, the submitting user identity, the query ID, the resource group assignment, and elapsed time. In a multi-tenant setup where tenant filter values or customer IDs appear in SQL (e.g., `WHERE tenant_id = 'acme'`), any tenant principal who can read this table sees every other tenant's active queries. This is a real data breach path, not a theoretical risk.

### How OPA enforces this

Your OPA Trino authorization policy receives an authorization request for every table access. The request includes the action type (e.g., `SelectColumns`), the catalog, schema, and table name, and the calling principal's identity (username, groups, JWT claims). Your policy returns `allow: true` or `allow: false`.

To block `system.runtime.queries` for non-admin principals:

- Identify admin principals by role, group membership, or a specific claim in their JWT (e.g., a `roles` claim containing `"trino-admin"`)
- Write a deny rule for the `system` catalog for any principal not in that admin set
- Allow the same access for admin principals

The specific Rego policy rules should be defined in your external governance document — the pattern is a deny-by-default on the `system` catalog that has a carve-out for principals matching the admin identity check.

### Scope the deny to the full `system` catalog, not just one table

`system.runtime.queries` is not the only leak path in the system catalog. Other tables to consider blocking for tenant principals:

- `system.runtime.tasks` — task-level execution breakdown
- `system.runtime.nodes` — cluster node topology (lower severity)
- `system.runtime.transactions` — active transaction state

Rather than blocking table by table, the recommended approach is to deny the entire `system` catalog for tenant principals and then add explicit allows only for any system tables that tenants legitimately need (typically none).

### Iceberg metadata tables also require blocking

Every Iceberg table exposes hidden metadata tables via the `$` suffix: `$snapshots`, `$history`, `$partitions`, `$files`, `$manifests`. These are accessible through Trino and can expose data distribution, partition values, and file paths — potentially revealing cross-tenant information in a shared schema setup. Your OPA policy should deny access to these metadata tables for tenant principals, restricting them to only the base tables they own.

### OPA advantages over file-based access control

OPA policies hot-reload without restarting the Trino coordinator. File-based access control (`rules.json`) requires a coordinator restart to take effect. For security-sensitive changes like blocking a system table that is actively leaking, hot-reload means the fix is effective immediately after the policy is pushed to OPA.

### Verifying the fix

After deploying the updated OPA policy, verify by authenticating as a tenant principal (not an admin) and running:

```sql
SELECT COUNT(*) FROM system.runtime.queries;
```

This should return an `Access Denied` error immediately — the query should not execute at all. Then verify that an admin principal can still run the same query successfully.
