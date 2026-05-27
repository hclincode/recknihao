# Iter85 Q1 — Answer

**Question**: Is OPA row-level filter injection real? How does it differ from views and from OPA allow/deny? Where does it live? When is it worth using over views?

---

## Answer

Yes, OPA row-level filter injection is absolutely real, and it's a powerful but different pattern than what you're already doing with views. Let me break down how it works and when it makes sense.

## What OPA row-filter mode actually does

When you configure OPA for **row-level filtering** on a table, here's what happens:

1. Your app sends a bare `SELECT * FROM analytics.events` with no WHERE clause.
2. Trino intercepts the query during the analysis phase (before it touches any data) and calls out to OPA, asking: "Can this user access this table, and if so, with what constraints?"
3. OPA evaluates its policy rules, looks up which tenant the calling principal belongs to, and returns not just "yes" but a SQL fragment: `{"rowFilters": [{"expression": "tenant_id = 'acme'"}]}`.
4. Trino's analyzer automatically rewrites your query as if you had written `SELECT * FROM analytics.events WHERE tenant_id = 'acme'`.
5. Only Acme's rows leave the engine. The application layer never saw the filter — it didn't have to write it.

This is fundamentally different from your current view-based approach, where you explicitly create `tenant_acme.events AS SELECT ... WHERE tenant_id = 'acme'` for every customer and grant them access only to that view.

## Where does it live?

The row-filter injection **does not live in Iceberg or MinIO**. It lives in the **Trino query analyzer** plus **OPA policy**:

- **OPA's job**: Store the mapping of "principal X belongs to tenant Y" and the rule that says "when someone queries `analytics.events`, inject `tenant_id = Y`". It returns that filter as JSON.
- **Trino's job**: Call OPA for every table reference during query analysis, get back the row-filter expression, and transparently append it as a WHERE clause before the query ever reaches the Iceberg connector or MinIO.

The base table (`analytics.events`) sits unchanged in MinIO; Trino is doing the work of restricting what rows come back.

## How it differs from per-tenant views

| Aspect | View-based | OPA row filters |
|--------|---------|---------|
| **Setup per tenant** | CREATE VIEW + GRANT per tenant | Write one OPA rule; add tenant as a mapping row. No SQL DDL. |
| **Maintenance at scale** | 500 tenants = 500 views + DDL migrations for schema changes | Single rule, scales horizontally |
| **Blast radius of a bug** | One misconfigured view affects only that tenant | A bug in the Rego rule breaks isolation for all tenants simultaneously |
| **Failure isolation** | Per-tenant — failures are contained | Global — Rego bugs are a single point of failure |
| **Auditability** | Easy — read the SQL view definition | Requires understanding Rego policies |

## When row filters are worth it

**Use OPA row filters if:**
- You have 50+ tenants and are adding them frequently — "add a mapping row" beats "CREATE VIEW + GRANT" at every tenant onboarding.
- You have a robust principal-to-tenant lookup (JWT claim or config table) that's reliably correct.
- Your team is comfortable maintaining and testing OPA policy code.

**Stick with per-tenant views if:**
- You have < 50 tenants and growth is slow — DDL overhead is manageable.
- You want one-at-a-time failure isolation — if one view is wrong, the other 49 still work.
- Your team wants security boundaries in SQL (which everyone understands) rather than Rego.

## The security testing difference

With views:
```sql
SELECT DISTINCT tenant_id FROM tenant_acme.events;  -- must return only 'acme'
```

With OPA row filters:
```sql
SELECT DISTINCT tenant_id FROM analytics.events;  -- as acme principal → must return only 'acme'
SELECT DISTINCT tenant_id FROM analytics.events;  -- as admin principal → returns all tenant IDs
```

Row filters require the same rigorous CI testing as views. A misconfigured OPA Rego rule exposes all tenants simultaneously — your team must be prepared for that operational model.

## The practical answer for your stack

You're on Trino 467 with OPA already configured. Row filters are available to you — they're part of the Trino OPA plugin. The specific Rego policy shape is in your external governance document. Whether to use them depends on:

1. **Tenant count and growth rate** — 50+ fast-growing tenants favors row filters; 20 stable tenants favors views.
2. **OPA policy confidence** — Row filters shift the security boundary from SQL to Rego. If your team would struggle to debug Rego, stick with views.
3. **Principal-to-tenant mapping reliability** — Row filters depend entirely on this being correct. If your JWT token doesn't reliably carry the tenant claim, views are safer.

You can also mix: use row filters for high-volume shared tables (operational simplicity) and keep per-tenant views for sensitive admin tables (easier to audit, contained blast radius).

The direct answer: yes, it's real, it lives in Trino + OPA together, and it's worth considering — but only if you have enough tenants and enough OPA maturity to justify the shift.
