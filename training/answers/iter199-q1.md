# Iter 199 Q1 — system.query() Security and OPA Enforcement

## Answer

**No, OPA row filters do NOT apply to queries run through `system.query()`.** This is a genuine security concern you should address immediately.

---

### The critical problem: `system.query()` bypasses Trino's query rewriting

`system.query()` works by sending the SQL string **verbatim** to Postgres via JDBC. Trino does not parse or rewrite it. This matters for security because OPA's row-filter enforcement works by rewriting queries at analysis time — Trino injects a WHERE predicate into the query plan before it executes.

When you call `system.query()`, you're bypassing that entire layer. The query string goes directly to Postgres unchanged. OPA never sees the table being queried, never injects a row-level WHERE clause, and never blocks the query.

---

### OPA still gates the function call itself, but that's not the barrier you need

OPA does check that the user is allowed to call table functions (the `SystemAccessControl.checkCanCallFunction()` method in Trino). So if your OPA policy explicitly denies all users except admins the right to invoke `system.query()`, you can prevent access. However, checking "can you call the function?" is different from checking "can you read these rows?" — and row-level isolation relies on OPA's row-filter mode combined with view-based access patterns.

---

### Why this is a hole in your multi-tenant setup

Your current isolation model relies on:
1. **Layer 1**: Views with hardcoded `WHERE tenant_id = 'acme'` filters
2. **Layer 2**: OPA denying tenants direct base-table SELECT (they only get SELECT on the view)
3. **Layer 3**: OPA row-filters on tables that get queried directly

`system.query()` bypasses ALL three layers. A tenant who calls:

```sql
SELECT * FROM TABLE(app_pg.system.query(
  query => 'SELECT * FROM public.accounts WHERE tenant_id != ''acme'''
))
```

skips:
- The view's WHERE clause (not involved)
- OPA's base-table SELECT denial (OPA sees a function call, not a table SELECT)
- OPA row-filters (Trino never rewrites the query, so the row-filter predicate is never injected)

---

### Practical guidance

**1. Block `system.query()` for tenant principals via OPA.**

Your OPA policy should explicitly deny `ExecuteQuery` / table-function invocations for all tenant principals. Only platform-admins or data engineers should be able to invoke `system.query()`.

```rego
# Deny system.query() for non-admin users
deny if {
  input.action.operation == "ExecuteTableFunction"
  input.action.resource.function.name == "query"
  not "platform-admin" in input.context.identity.groups
}
```

**2. Make `system.query()` a mandatory code review point.**

Any use of `system.query()` on a Postgres table containing customer data should trigger a security review, because it's a manual SQL-injection point. The person writing it must hand-code the tenant isolation filter, and there is no automated enforcement. Anything that bypasses Trino's normal SQL analysis layer bypasses OPA row filters.

**3. Prefer views or normal table reads.**

For customer-facing or regular reporting queries, stick with Trino's normal table access patterns where row-filters apply. Reserve `system.query()` for internal diagnostics, introspection (pg_catalog, pg_stat_* views), or Postgres-specific syntax that Trino genuinely cannot express. Never use it as an "escape hatch" for customer data queries.

---

### Summary

| Enforcement layer | Normal Trino SELECT | `system.query()` |
|---|---|---|
| OPA table access check | YES — blocks unauthorized tables | NO — OPA sees a function call, not a table |
| OPA row-filter injection | YES — WHERE predicate injected before execution | NO — SQL sent verbatim to Postgres |
| OPA column masking | YES | NO |
| Postgres-side filters | Not applicable by default | Up to the raw SQL string in the call |

**Bottom line: `system.query()` is an authorized escape hatch that intentionally bypasses Trino's analysis layer — and with it, all OPA tenant isolation. Block it for tenant principals via OPA `ExecuteTableFunction` denial, and treat any internal use as a security-reviewed exception.**
