# Iter 198 Q1 — Multi-Tenant Federation Isolation

## Answer

## What OPA Can Guarantee

**OPA's row-filter mode can automatically enforce per-tenant isolation even if your application layer forgets the `WHERE tenant_id` filter.** This is the direct answer to your question.

When you configure Trino with OPA's row-filter policy on the Postgres-backed tables, OPA intercepts every query at the analysis phase (after parsing, before execution) and injects a `WHERE tenant_id = '<caller_tenant>'` predicate. The application can send a bare `SELECT * FROM postgres_table`, and Trino will rewrite it to `SELECT * FROM postgres_table WHERE tenant_id = 'customer_a'` based on the OPA policy. Only Customer A's rows are fetched from Postgres and only Customer A's rows are returned.

**This solves your stated problem:** a query-translation bug that omits the tenant filter will not cause a cross-tenant leak because OPA enforces the filter at the query engine level, not relying on your application.

---

## What OPA Cannot Guarantee

OPA's row-filter injection operates at **the Trino level only**. It does not secure the Postgres database itself. Here is what that means in practice:

1. **If someone connects to Postgres directly (outside Trino), OPA is bypassed entirely.** Postgres itself has no enforced row-level security unless you set it up. If a compromised credential or rogue operator connects to the Postgres primary directly and runs `SELECT * FROM tenants` without a WHERE clause, they see every customer's data. OPA cannot prevent this because it only runs inside Trino's query analysis, not on the Postgres side.

2. **OPA sees only the Trino username and groups, not tenant identity in the JWT claims.** Trino 467's OPA integration does not receive JWT claims—only the Trino username that the JWT authenticator derived from the JWT. You must encode tenant identity either (a) in the Trino username itself (e.g., `acme--svc` where `acme` is the tenant), or (b) in an external OPA data bundle that maps Trino usernames to tenants. If this mapping is wrong or stale, OPA's row filter will inject the wrong tenant ID and Customer A may see Customer B's data. This is a misconfiguration risk at the OPA level, not a limitation of OPA's capability, but it matters for your threat model.

3. **Postgres views do NOT provide additional isolation when queries come through Trino's Postgres connector.** Trino's PostgreSQL connector executes the query you send to Postgres directly. If you wrap the base table in a Postgres view with a `WHERE tenant_id = 'acme'` filter, Trino will still push down predicates into the view, and the view's filter will apply—but **this is weaker than OPA enforcement** because:
   - The view is a schema-level artifact; it only helps if your access control explicitly revokes direct base-table access and grants view-only access at the Postgres level. Trino does not coordinate with Postgres-level GRANTs—Trino's access control (OPA) is independent of Postgres permissions.
   - A mistake in your Postgres view definition is not caught by Trino. Trino just executes what the connector returns.
   - Postgres views don't prevent direct Postgres connections (the same problem as above).

---

## Recommended Approach: Defense in Depth

For your multi-tenant SaaS, combine three layers:

1. **OPA row-filter policy on the Postgres catalog in Trino** (your query engine). This is the primary defense for application-layer bugs. OPA injects `WHERE tenant_id = '<tenant>'` automatically, so a forgotten filter in your query-translation layer is caught here.

2. **Postgres views + Postgres role-based access control** (optional but recommended). Create per-tenant views in Postgres that hard-code `WHERE tenant_id = <tenant>`, and grant each customer role SELECT only on the scoped view, not on the base table. This provides defense-in-depth if:
   - Someone attempts to bypass Trino and query Postgres directly.
   - There is a misconfiguration in Trino's access control.
   
   However, Postgres RLS (row-level security) is the more robust form of this defense if you can enable it—RLS uses policies that enforce row filtering at the storage engine level, not view-level filtering. Classic views are still better than nothing but weaker.

3. **Test the isolation boundary in your CI/CD pipeline**:
   - As each tenant principal, run `SELECT DISTINCT tenant_id FROM <postgres_table>` through Trino and assert it returns exactly one row (their own tenant).
   - As an admin principal (with OPA carve-out), the same query should return all tenants.
   - If a tenant principal ever sees more than one `tenant_id`, the OPA row-filter Rego is misconfigured—treat as a P0 data leak.

---

## Critical Implementation Details for Your Stack

**OPA row-filter mode requires that Trino knows the calling tenant.** In your JWT-based production stack, the tenant identity must be encoded in the JWT. Per the official Trino OPA integration, OPA receives **only the Trino username** (what the JWT authenticator extracted), **not JWT claims**. So:

- If your JWT has a `tenant_id` claim, your JWT authenticator must map that claim into the Trino username (e.g., extract `acme` from the `tenant_id` claim and set the Trino username to `acme--svc`), OR
- Your OPA data bundle must contain a lookup table that maps Trino usernames to tenants (e.g., `"acme-service-account"` → `"acme"`).

If the mapping is wrong or missing, OPA injects the wrong `WHERE` clause and isolation is broken.

**The PostgreSQL connector does not natively pool JDBC connections**, so configure **PgBouncer** between Trino and Postgres (in transaction pooling mode) to bound the connection count. Also set a Postgres role-level `CONNECTION LIMIT` on the Trino user and cap concurrent Postgres connector queries via Trino resource groups. This prevents the Postgres side from being overwhelmed by Trino workers.

---

## Bottom Line

**Yes, OPA row-filter mode can guarantee that even if your application layer forgets the `WHERE tenant_id` filter, Trino will inject it automatically.** This solves your stated problem of query-translation bugs causing cross-tenant leaks through Trino.

What it does NOT guarantee is isolation if someone connects to Postgres directly outside Trino, or if your OPA tenant-identity mapping is misconfigured. For production, add Postgres-side view + access control (or RLS) as a second layer, and test both layers with tenant-scoped CI assertions.
