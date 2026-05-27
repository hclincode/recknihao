# Iter 209 Q2 — Cross-Catalog View Permissions in OPA: Security DEFINER vs INVOKER

## Answer

Based on the resources, here's how OPA and Trino views interact with row-level security — and the critical security distinction you need to understand:

**The short answer: OPA evaluates the underlying base tables, not just the view. But the security model depends on which SECURITY mode your view uses.**

---

### How Trino processes views and where OPA checks happen

When you query a view that joins `iceberg.analytics.events` and `app_pg.public.tenants`, Trino does NOT treat it as a single opaque resource. Instead:

1. **During query analysis (before execution), Trino expands the view.** It resolves the SQL text into the underlying tables it references — in your case, both `events` and `tenants`.
2. **OPA is consulted during this analysis phase.** Trino makes multiple HTTP calls to OPA — one per resource access check — covering each table referenced in the view expansion. Each table referenced generates its own OPA check.
3. **OPA sees the resolved table list, not just the view name.** When Trino executes a query, the engine's analyzer resolves every table reference (including those hidden in views, subqueries, and CTEs) to its real `catalog.schema.table` name. OPA receives these resolved table names in the `SelectFromColumns` operation and evaluates them against your policies.

So no — OPA does NOT skip checking the individual tables just because you wrapped them in a view. Your concern about a view becoming a "backdoor" is legitimate without the right security mode.

---

### The critical difference: SECURITY DEFINER vs SECURITY INVOKER

This is where the distinction saves you. Trino views support two modes that determine whose grants are used to read the base tables:

**`SECURITY DEFINER` (Trino's default)**
- The view executes with the **view owner's grants**, not the caller's.
- The caller only needs `SELECT` on the view itself.
- OPA still checks the underlying tables during analysis, but against the **view owner's identity**, not the tenant's.
- If the view owner has SELECT on both `events` and `tenants`, the view body can read both. The tenant caller cannot read them directly, but the view can on their behalf.
- **Best for:** Tenant isolation where analysts have NO direct base-table grants. The view is the only path to the data.

**`SECURITY INVOKER`**
- The view executes with the **calling user's grants**.
- The caller must have SELECT on every base table the view touches, or the query fails with `Access Denied`.
- OPA checks both tables against the **caller's identity**.
- **Best for:** Trusted analysts who already have base grants, or when you explicitly want underlying access controls (Postgres GRANTs, OPA row-filter / column-mask policies) to apply.

---

### How to keep your row-level security intact

**1. Use `SECURITY DEFINER` (the default) if tenants do NOT have direct base-table access.**

This is the standard tenant-isolation pattern. Create the view with:

```sql
CREATE VIEW analytics.events_with_tenants AS
SELECT e.event_id, e.occurred_at, e.tenant_id, t.tenant_name
FROM iceberg.analytics.events e
JOIN app_pg.public.tenants t ON e.tenant_id = t.id;
```

The view owner reads both tables; the tenant only reads through the view. OPA verifies the view owner has access to both tables, not the tenant.

**2. Ensure OPA denies direct base-table access for tenant principals.**

Even with DEFINER mode, configure your OPA policy to explicitly deny tenant principals from querying `iceberg.analytics.events` or `app_pg.public.tenants` directly. This is belt-and-suspenders: the view mode gates access at the privilege level; OPA gates it at the policy level.

**3. Use `SECURITY INVOKER` ONLY if you want row-filters to flow through the view.**

If your OPA policy has row-filter rules that inject `WHERE tenant_id = 'acme'` for the calling user, and you want those filters to apply when querying through the view, use INVOKER. But then tenants must have direct base-table SELECT grants (which contradicts the typical tenant-isolation setup).

**4. Never use `SELECT *` in the view.**

With `SECURITY DEFINER` + `SELECT *`, every column added to `tenants` on the Postgres side becomes accessible to every user with SELECT on the view, automatically. Use explicit columns to prevent this.

**5. Test it.**

Run a per-tenant CI check: as each tenant principal, `SELECT DISTINCT tenant_id FROM <their_view>` must return exactly one value — their own. If it returns more, your policy has a gap.

---

### Summary

| Concern | What actually happens |
|---|---|
| Does OPA check underlying tables? | Yes — view expansion happens before OPA evaluation |
| Does the view bypass row-filter policies? | Only if you use SECURITY DEFINER and the view owner's identity has access; the caller's policies don't apply |
| Can a view become a backdoor? | Yes, if you rely on INVOKER mode but don't give callers base-table grants — or if DEFINER mode + OPA doesn't explicitly deny direct base-table access |
| Correct setup for tenant isolation | SECURITY DEFINER + OPA policy denying tenants from direct base-table SELECT + explicit column list |

Your view does NOT become a backdoor if you use SECURITY DEFINER for tenant isolation, combine it with OPA policies that deny direct base-table access for tenants, and list columns explicitly (no `SELECT *`).
