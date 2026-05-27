# Iter 205 Q1 — OPA Row Filters vs Column Masking: Decision Framework

## Answer

### 1. Three OPA Access Control Levels

Trino's OPA plugin supports three distinct mechanisms that work independently and can be layered:

**Allow/Deny Mode** (`opa.policy.uri`)
- OPA returns `{"allow": true}` or `{"allow": false}`
- Trino either lets the query proceed unchanged or rejects it with `Access Denied`
- Use case: block tenants from accessing the `system` catalog, deny entire tables, gate admin-only resources
- This is what you already have working. It's a binary gate — the user either can mention the table at all, or cannot.

**Row Filter Mode** (`opa.policy.row-filters-uri`)
- OPA returns `{"rowFilters": [{"expression": "tenant_id = 'acme'"}]}`
- Trino appends the expression as a `WHERE` predicate before executing the query
- Crucially: **the WHERE is applied automatically by the query engine; the client cannot bypass it** even if they forget to write it
- Use case: multi-tenant fact tables where you want OPA to enforce per-tenant filtering without trusting the client

**Column Masking Mode** (`opa.policy.batch-column-masking-uri`)
- OPA returns `[{"index": N, "viewExpression": {"expression": "to_hex(sha256(...))"}}]`
- Trino substitutes that SQL expression for the column at query analysis time
- The client receives the masked value, not the raw column
- Use case: allow column access but redact or hash sensitive values per role

The key insight: **Allow/deny is binary (table accessible or not). Column masking is "let them see the column but return a masked value." Row filters are "let them see the table but only these rows."**

---

### 2. Column Masking — Why It Differs from SelectFromColumns Deny

In your current setup, when you write an OPA rule that denies `SelectFromColumns` on `phone_number`, you're blocking the column entirely. The query fails with `Access Denied`. That's heavy-handed.

Column masking lets you **let the query succeed but transform the value**. Here's the difference:

```
Deny (SelectFromColumns deny):
User: SELECT name, phone_number FROM app_pg.public.users
Result: Access Denied — query fails

Column masking:
User: SELECT name, phone_number FROM app_pg.public.users
Result: Success; Trino rewrites to:
        SELECT name, to_hex(sha256(to_utf8(phone_number))) AS phone_number
        FROM app_pg.public.users
        Returns: name='Alice', phone_number='a4f2c8d9...'
```

The user can still query the table. They get every row they're authorized to see. But the `phone_number` column contains a hash instead of the raw value.

**Important caveat**: Column masking applies at query analysis time inside Trino. The raw bytes still flow through worker memory during query execution — the mask only guarantees the **returned value** is masked, not that the raw data never entered the query engine. For the common case (worker pods are trusted, analysts shouldn't see raw PII), this is exactly right.

---

### 3. Row Filters — How They Enforce Tenant Isolation Without Client Trust

Row filters solve your second problem directly: **"let them query the table but only get rows where tenant_id matches their own tenant."**

When you configure `opa.policy.row-filters-uri`, OPA receives the query context and returns a filter predicate. Trino appends it before execution:

```
User acme--analyst queries: SELECT * FROM app_pg.public.users
OPA sees: user = "acme--analyst"
OPA returns: {"rowFilters": [{"expression": "tenant_id = 'acme'"}]}
Trino rewrites to: SELECT * FROM app_pg.public.users WHERE tenant_id = 'acme'
Result: Only Acme's rows, automatically
```

The critical part: **the filter is enforced by the query engine before rows are returned to the client.** Even if the user tries `SELECT * FROM app_pg.public.users` with no WHERE clause, Trino injects the `tenant_id = 'acme'` predicate.

**How tenant identity is extracted**: OPA only receives `{user, groups}` after authentication — NOT raw JWT claims. You encode tenant identity in one of two patterns:

Pattern 1 (username convention): Trino username is `acme--svc`. In Rego:
```rego
tenant := split(input.context.identity.user, "--")[0]  # Extracts "acme"
```

Pattern 2 (data bundle lookup): Maintain a mapping in OPA's data bundle:
```rego
tenant := data.tenant_map[input.context.identity.user]
```

---

### 4. Do Row Filters and Column Masks Interact? Does Order Matter?

**Yes, they compose. No, order doesn't matter in a problematic way.**

The composition works like this:
1. **Allow/deny first** — guards what tables a tenant can touch at all
2. **Row filters** — constrain which rows they see from tables they ARE allowed to touch
3. **Column masks** — independently transform individual column values at query analysis time

A single query sees both effects:

```
SELECT name, phone_number FROM app_pg.public.users

→ OPA row filter: WHERE tenant_id = 'acme'
→ OPA column mask: phone_number → to_hex(sha256(to_utf8(phone_number)))

Trino rewrites to:
SELECT name, to_hex(sha256(to_utf8(phone_number))) AS phone_number
FROM app_pg.public.users
WHERE tenant_id = 'acme'
```

There is no weird interaction — they don't "fight." Both apply to the same query.

**One gotcha**: If you mask a column to a constant (like `'****'`), then `GROUP BY phone_number` collapses to one group. Use a deterministic hash (`to_hex(sha256(to_utf8(phone_number)))`) to preserve equality so grouping and joining still work correctly.

---

### 5. Concrete Config and OPA Response Examples

**Trino configuration** (`etc/access-control.properties`):

```properties
access-control.name=opa
opa.policy.uri=http://opa:8181/v1/data/trino/allow
opa.policy.row-filters-uri=http://opa:8181/v1/data/trino/rowFilters
opa.policy.batch-column-masking-uri=http://opa:8181/v1/data/trino/batchColumnMask
```

Use the batch endpoint for column masking to avoid per-column HTTP round-trips on wide tables.

**What OPA returns when user `acme--analyst` (non-internal) queries `SELECT name, phone_number FROM app_pg.public.users`:**

Row filter response:
```json
{"rowFilters": [{"expression": "tenant_id = 'acme'"}]}
```

Batch column mask response:
```json
[
  {"index": 0, "viewExpression": {"expression": "name"}},
  {"index": 1, "viewExpression": {"expression": "to_hex(sha256(to_utf8(phone_number)))"}}
]
```

**Trino rewrites the query to:**
```sql
SELECT name, to_hex(sha256(to_utf8(phone_number))) AS phone_number
FROM app_pg.public.users
WHERE tenant_id = 'acme'
```

**For an internal user** (with `internal-analyst` in their groups): OPA returns `phone_number` as the expression (no masking). They see raw phone numbers.

---

### Key Takeaways for Your Setup

1. **Allow/deny is the wrong tool for "let them see the table but hide a column."** It blocks access entirely.
2. **Column masking lets them query the table; the masked column returns a hash or literal** — not a denial.
3. **Row filters enforce per-tenant filtering at the query engine level** — client cannot bypass it by omitting a WHERE clause.
4. **Use the batch column masking endpoint** (`batch-column-masking-uri`) to avoid per-column HTTP round-trips.
5. **Both row filters and column masks apply to the same query** — they compose, and you almost always want both in a multi-tenant setup.
6. **Tenant identity must be derivable from `{user, groups}`** — OPA never sees the raw JWT claims.

**Verification queries:**
- `SELECT DISTINCT tenant_id FROM app_pg.public.users` — must return exactly their tenant
- `SELECT phone_number FROM app_pg.public.users LIMIT 1` — internal user sees raw phone; others see hash
