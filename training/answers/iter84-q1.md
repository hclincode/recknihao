# Iter84 Q1 — Answer

**Question**: How to enforce row-level tenant isolation in Trino so that queries without WHERE tenant_id = ? can't accidentally leak cross-tenant data? What is OPA and how does it connect to Trino?

---

## Answer

You're right to worry about the application-layer WHERE clause being your only defense — that's a common and dangerous pattern. The good news is Trino has two proven ways to enforce tenant isolation at the query-engine level so even a forgotten WHERE clause can't leak data.

### The Two Approaches: Views (Simpler) vs. OPA (More Powerful)

**Approach 1: Trino Views with Baked-In Tenant Filters (Simpler)**

Instead of letting customers query your base `analytics.events` table directly, you create a separate view for each tenant with the tenant filter hard-coded into the view definition. Think of it like a one-way mirror — customers can only see their own data because the view physically cannot return anything else.

```sql
-- Base table: only your internal data team can query this
CREATE TABLE analytics.events (
  event_id    BIGINT,
  tenant_id   VARCHAR,
  user_id     VARCHAR,
  event_type  VARCHAR,
  ...
);

-- Per-tenant view: hard-coded filter
CREATE VIEW tenant_acme.events AS
  SELECT event_id, user_id, event_type, ...
  FROM analytics.events
  WHERE tenant_id = 'acme';

-- Grant access: Acme's service account can only read the view, NOT the base table
GRANT SELECT ON tenant_acme.events TO ROLE acme_role;
-- Revoke base table access (critical!)
REVOKE ALL PRIVILEGES ON analytics.events FROM USER "acme-service-account";
```

What happens at the Trino query engine level: When Acme's service account tries to run `SELECT * FROM tenant_acme.events`, Trino evaluates whether they have permission to read that view (yes), then executes the view's underlying query with the WHERE clause baked in. If they try to query `analytics.events` directly (forgetting the tenant filter, or an application bug), Trino's access control layer rejects it with an "Access Denied" error *before* the query engine even looks at the data. **The rejection happens during the analysis phase, before any files are opened on MinIO.** This is your isolation boundary.

**Pros**: Simple to understand and maintain. For 80 tenants, you create 80 views and 80 roles — a one-time setup cost that fits into a provisioning script.

**Cons**: You have to create a view explicitly for each new tenant. It doesn't scale elegantly past ~200 tenants.

---

**Approach 2: OPA (Open Policy Agent) — More Powerful, More Complex**

OPA is an external policy engine — a separate service you run that Trino calls out to on every query to ask "is this user allowed to read this table?" The key difference from views is that OPA can make authorization decisions *dynamically* based on rules you write, without creating individual SQL objects for each tenant.

To demystify "OPA": imagine a security guard who sits at the gate and checks every person against a rulebook:
- **The security guard** = the OPA service running as a separate process (typically in Kubernetes, alongside your Trino cluster).
- **The rulebook** = a policy file written in a language called Rego, checked into git like normal code.
- **The gate** = every time Trino receives a query, it pauses at the analysis phase and asks OPA: "Can this user read this table?" OPA evaluates the rulebook, returns yes/no, and Trino either continues or rejects the query.

**A concrete OPA rule in Rego pseudocode:**

```
# Rego pseudocode — actual policies live in your external governance document
if (principal == 'acme-service-account' AND table == 'analytics.events') {
  deny  # base table is off-limits
}
if (principal == 'acme-service-account' AND table == 'tenant_acme.events') {
  allow  # only the view
}
if (principal == 'data-team' AND table == 'analytics.events') {
  allow  # internal team can read base tables
}
```

**Pros**:
- Highly flexible. One rule can apply to all tenants at once — e.g., "deny any tenant access to the `system` catalog" (which exposes metadata leaks like other tenants' query text).
- Policy changes are hot-reloaded: push a new Rego rulebook to OPA, and within seconds every subsequent query uses the new policy. No Trino restart required.
- Easier to scale to large numbers of tenants.

**Cons**: Requires operational maturity. You need to understand how to write Rego policies, version-control them, and debug policy evaluation. On your production stack, OPA policies are defined in an external governance document — you won't write the Rego yourself, but you need to work with the platform team that maintains it.

---

### What Happens When Someone Forgets the WHERE Clause?

Let me be concrete: "someone writes a quick ad-hoc query and forgets `WHERE tenant_id = ?`."

**With the view approach**: They authenticate as the Acme service account and run `SELECT COUNT(*) FROM analytics.events` (the base table, no WHERE clause). Trino's access control plugin checks whether acme-service-account has SELECT permission on analytics.events. The answer is no (you revoked it). Trino rejects the query with `Access Denied` during analysis. The query never reaches MinIO, and Acme sees only an error message.

**With OPA**: Same outcome. OPA evaluates the rule and returns deny. Trino rejects the query.

In both cases, the application layer's WHERE clause is no longer the isolation boundary — Trino itself is.

---

### A Critical Implementation Detail: You Must Revoke Base-Table Access

```sql
-- WRONG — incomplete (missing the revoke!)
GRANT SELECT ON tenant_acme.events TO ROLE acme_role;

-- CORRECT — complete
GRANT SELECT ON tenant_acme.events TO ROLE acme_role;
REVOKE ALL PRIVILEGES ON analytics.events FROM USER "acme-service-account";  -- REQUIRED
```

Why this matters: Trino's default permission model is "allow everything by default." Creating a role and granting it view access doesn't automatically revoke the user's pre-existing implicit access to the base table. If you skip the REVOKE, the user can bypass the view entirely and query the base table directly — the view's isolation is defeated.

---

### Which Approach for Your 80-Tenant SaaS?

**Use views if** you have < 150 tenants and can tolerate creating one view per tenant as part of your onboarding script. Simple, auditable, no external services.

**Use OPA if** you have > 150 tenants or need policy changes to apply instantly to all tenants at once, or have complex governance rules (e.g., business-unit scoping within a tenant).

Your production environment is already using OPA — the infrastructure is in place. A practical combination: use views for per-row tenant isolation, and lean on OPA's system-catalog deny rules to block cross-tenant metadata leaks (like the `system.runtime.queries` table that can expose other tenants' SQL text).

Test your setup by connecting as the acme role and confirming:
- `SELECT COUNT(*) FROM analytics.events` → fails with `Access Denied`
- `SELECT COUNT(*) FROM tenant_acme.events` → succeeds, returns only acme's rows
