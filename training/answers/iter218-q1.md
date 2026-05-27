# Iter 218 Q1 — What OPA Sees When You Query a Trino View (Cross-Catalog View + OPA)

## Answer

## What OPA Sees When You Query a Trino View

Your concern is well-founded. **OPA evaluates access in TWO separate checks** — not one — when a view is queried. Understanding which check applies to which tables and which identity is used for each check is critical to your access control model.

### The Two-Check OPA Model for Views

When someone queries a view, Trino sends **two distinct OPA policy evaluation requests**, one after the other:

**Check 1: View-level access** — Trino evaluates whether the **caller (the person running the query)** has SELECT permission on the **view object itself**. This check uses the caller's identity. If you have a row-filter policy configured against the view, it fires here with the caller's identity.

**Check 2: Base-table access** — Trino then evaluates whether the **view owner** has SELECT permission on **each underlying base table** referenced inside the view body (in your case, the Iceberg events table AND the Postgres users table). This check uses the **view owner's identity**, NOT the caller's identity.

This is the critical detail: **row-level OPA restrictions configured on the base tables fire under the view owner's principal, not the original caller's principal.**

### Row-Level Filter Behavior Through Views

Here's the key issue: if you have a row-level filter configured via `opa.policy.row-filters-uri` on your Postgres users table, that filter will:

1. **Fire when the view is queried**, but
2. **Fire under the view owner's identity**, not the analyst's identity
3. This means the row filter evaluates `tenant_id = '<view-owner-tenant>'`, NOT `tenant_id = '<analyst-tenant>'`

So if your view owner is a service principal (like `svc-trino-views`) that has access to all tenants' data, the Postgres row-level filter won't actually restrict which rows come back to the caller — it will allow all rows the service principal can see.

**Why this matters:** If you're relying on `opa.policy.row-filters-uri` on the Postgres side to enforce per-tenant isolation when analysts query through a view, you are **not getting that isolation**. The restriction fires under the wrong identity.

### WHERE Clause Pushdown Through Views

Good news here: **WHERE clauses DO push down to Postgres when you query through a view**, provided your predicates are supported by the PostgreSQL connector.

When you submit a query like:

```sql
SELECT * FROM analytics.events_with_accounts WHERE user_id = 123;
```

Trino:
1. Evaluates OPA (the two checks above)
2. Injects any OPA row-filter predicates from the view-level check (Check 1)
3. **Expands the view body** — replacing the view reference with the underlying SELECT query
4. **Combines your WHERE clause** (`user_id = 123`) with any OPA-injected predicates
5. **Pushes the combined predicate down to Postgres** if all conditions are met (no unsupported functions, no collation mismatches, etc.)

So the actual SQL Postgres receives is something like:

```sql
SELECT [...columns...] FROM public.users WHERE user_id = 123 AND [any OPA-injected filters];
```

Postgres handles the filtering server-side, and Trino only receives the matching rows.

**Important caveat:** Pushdown does NOT happen for all predicate types. LIKE and ILIKE on strings do not push down by default to Postgres in Trino 467; string range comparisons (>, <, BETWEEN) on VARCHAR columns have collation-safety caveats.

### The Identity Problem: SECURITY DEFINER vs. SECURITY INVOKER

Your view is almost certainly using **`SECURITY DEFINER`** (Trino's default). This is the root of the issue:

- **Under SECURITY DEFINER:** The view body executes with the **view owner's grants**, and all base-table access (including OPA row-filter checks) happens under the view owner's identity.
- **Under SECURITY INVOKER:** The view body executes with the **caller's grants**, and base-table access happens under the caller's identity. OPA row filters attached to the base table fire under the caller's identity, which is what you probably want for per-caller isolation.

If your view is DEFINER (the default) and you need per-caller row-level restrictions on the Postgres side, you have two options:

1. **Attach the row-filter policy to the VIEW, not the base table.** Create an OPA row-filter rule that matches on the view object, not the Postgres table. This fires in Check 1 (caller identity), gets injected as a WHERE clause, and flows down to Postgres in the combined predicate.

2. **Switch the view to SECURITY INVOKER** — but this requires the analyst to have direct base-table SELECT permission on the Postgres users table, which may be a bigger ask for your access control model.

The recommended approach for tenant-isolation patterns: attach row filters to the view, keep the view DEFINER, and let the service principal that owns the view have straightforward "SELECT on all base tables" permissions.

### How to Verify What OPA Is Actually Checking

Use the **OPA decision log** — this is the authoritative audit trail. When a query runs, Trino sends OPA decision logs that show:

- `input.context.identity.user` — whose identity was used for this OPA check
- `input.action.operation` — the type of check (e.g., `SelectFromColumns`)
- `input.action.resource.table.{catalogName, schemaName, tableName}` — which table OPA was asked about
- `result.allow` — whether the check passed

For a query against your view, you'll see **at least three entries** in the OPA decision log:

1. `SelectFromColumns` on `analytics.events_with_accounts` (the view), identity = the caller
2. `SelectFromColumns` on `iceberg.analytics.events` (base table), identity = the view owner
3. `SelectFromColumns` on `app_pg.public.users` (base table), identity = the view owner

If you have row-filter policies configured, you'll also see entries with `operation = "GetRowFilters"` (or similar, depending on your Trino version). Check which table those are firing on and which identity they use — that's where you'll discover whether Postgres row restrictions are being enforced under the caller or the owner.

### Bottom Line for Your Setup

To avoid accidentally bypassing Postgres row-level restrictions when queries go through the view:

1. **Verify your view's SECURITY mode** — `SHOW CREATE VIEW <view>;` and check whether it says `SECURITY DEFINER` or `SECURITY INVOKER`.

2. **If DEFINER (default):** Attach per-caller row filters to the **view object in OPA**, not to the Postgres base table. The view-level filter fires under the caller's identity and gets pushed down to Postgres.

3. **If INVOKER:** Make sure analysts have direct SELECT on the Postgres users table via OPA or your access control mechanism. Base-table filters will then fire under the analyst's identity.

4. **Test with OPA decision logs** — query them to confirm which identity OPA is using when base tables are accessed, and confirm which tables row filters are being attached to.

5. **Use EXPLAIN (TYPE DISTRIBUTED)** on a test query to confirm that the WHERE clause is actually being sent to Postgres (look for the predicate in the TableScan operator's constraints) rather than Trino filtering in-memory.
