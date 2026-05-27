# Iter 172 Q1 — Trino View Security: DEFINER vs INVOKER for Cross-Catalog Views

## Answer

You're asking the right question — views don't act like database-level permission boundaries the way a Postgres role-owned view does. Here's what actually happens on your Trino 467 stack.

### (1) How Trino View Security Modes Work

Trino supports **two security modes** that control **whose grants are used to read the base tables** the view touches:

- **`SECURITY DEFINER`** (Trino's **default** — no explicit clause needed): the view body executes with the **view owner's grants**. Analysts only need `SELECT` on the view itself.
- **`SECURITY INVOKER`**: the view body executes with the **calling user's grants**. Analysts must have `SELECT` on every base table the view touches.

This is the critical knob. It controls whether the analyst needs direct access to the underlying Postgres catalog and Iceberg catalog.

### (2) What Permissions Analysts Need Under Each Mode

**Under `SECURITY DEFINER` (the default):**
- Analysts need: `SELECT` on the view only — nothing else.
- They do NOT need `SELECT` on `app_pg.public.accounts` or `iceberg.analytics.events`.
- The view owner (a privileged service account) holds SELECT on both base tables.

**Under `SECURITY INVOKER`:**
- Analysts must have `SELECT` on both `app_pg.public.accounts` AND `iceberg.analytics.events`.
- If they lack either grant, the view query fails at planning with `Access Denied`.
- This gives analysts a much wider grant surface — most teams don't want this for cross-catalog views.

### (3) Default Mode and Its Implications

**The default is `SECURITY DEFINER`.** If you write:

```sql
CREATE VIEW analytics.customer_activity AS
SELECT
  e.event_id,
  e.user_id,
  a.account_id,
  a.account_name,
  a.plan_tier
FROM iceberg.analytics.events e
JOIN app_pg.public.accounts a ON e.user_id = a.account_id;
```

...without specifying a `SECURITY` clause, Trino treats it as `SECURITY DEFINER` automatically. This is the correct choice for most cross-catalog setups because analysts have no direct base-table grants.

### (4) The Sensitive-Column Leak Risk with DEFINER + SELECT *

**This is the attack surface you need to know about:**

With `SECURITY DEFINER` and `SELECT *` in your view, **every new column added to the base table becomes accessible to every analyst with SELECT on the view, automatically, without any ALTER VIEW or re-grant.**

Concretely: if your Postgres `accounts` table later gets a new `ssn` or `payment_token` column, and the view uses `SELECT *`, that column is immediately visible to every analyst querying the view — because the view owner can read it, so the view body can read it, so the view exposes it.

**Defense: always use an explicit column list. Never use `SELECT *`:**

```sql
-- GOOD — explicit columns
CREATE VIEW analytics.customer_activity AS
SELECT
  e.event_id,
  e.user_id,
  a.account_id,
  a.account_name,
  a.plan_tier        -- explicit
FROM iceberg.analytics.events e
JOIN app_pg.public.accounts a ON e.user_id = a.account_id;

-- BAD — SELECT * exposes all current AND future columns automatically
```

New columns stay hidden until you explicitly add them to the view definition. This forces a code review step for any new sensitive data in the base table.

### (5) How OPA Integrates with View-Based Access Control

On your production stack, **OPA is the authorization backend**, not SQL `GRANT`/`REVOKE`. This is critical:

When you grant analysts `SELECT` on the view, that grant is enforced by OPA — not stored in Trino's catalog. Your OPA Rego policy explicitly allows the analyst's principal to `SELECT` on the view.

**Three-layer defense-in-depth for cross-catalog views:**

1. **Layer 1 — Explicit column list in the view**: Only the columns you intentionally expose are readable. New sensitive columns in the base table stay hidden.

2. **Layer 2 — OPA denies direct base-table access**: Your OPA policy explicitly denies analysts any direct `SELECT` on `app_pg.public.accounts` or `iceberg.analytics.events`. They can ONLY reach the data through the view.

3. **Layer 3 — OPA denies system catalog and metadata leaks**: OPA rejects queries against `system.runtime.queries` and Iceberg metadata tables.

**Key point: SQL GRANTs are a no-op on your OPA-backed stack.** The view + OPA policy is your actual enforcement layer.

To verify isolation is working: as an analyst, run:
- `SELECT * FROM analytics.customer_activity` — should succeed.
- `SELECT * FROM app_pg.public.accounts` — should fail with `Access Denied` (rejected by OPA).

If the second query succeeds, your OPA policy is not denying direct base-table access.

### (6) Concrete Recommendations

```sql
-- Use SECURITY DEFINER (the default — no explicit clause needed).
-- Analysts have no direct base-table grants.
-- The view owner (privileged service account) holds SELECT on both tables.
CREATE VIEW analytics.customer_activity AS
SELECT
  e.event_id,
  e.event_time,
  e.user_id,
  a.account_id,
  a.account_name,
  a.plan_tier
FROM iceberg.analytics.events e
JOIN app_pg.public.accounts a ON e.user_id = a.account_id;
```

**Use `SECURITY INVOKER` only if:**
- Analysts already have direct `SELECT` on the base tables (unusual in multi-tenant setups).
- You want OPA's row-level filtering or column masking on the base table to apply equally to view queries.

**Operationally:**
1. **Never use `SELECT *` in views.** Always name columns explicitly.
2. **After Postgres schema changes**, verify the view still resolves: run `SHOW CREATE VIEW analytics.customer_activity`.
3. **Update the OPA policy, not SQL GRANTs**, when permissions change.
