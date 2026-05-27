# Answer to Q1: OPA columnMask for Per-Column PII Redaction (Iter 313)

You're right that duplicating the table is painful — and you don't need to do it. You already have OPA set up for row-level filtering. Your production environment supports **OPA column masking**, which is the exact tool for this: it lets you keep one table and selectively hide or transform specific columns per user, just like you're doing with rows.

## The Quick Answer

**Column masking in OPA** lets you specify — through policy rules, not by creating separate tables — that certain users see certain columns rewritten. For example, when your customers query the `events` table, the `email` column gets hashed, and the `user_name` column becomes `'****'`. The table stays singular; OPA returns masking expressions and Trino's planner applies them at query analysis time.

## How It Works

When a dashboard user runs `SELECT email, event_name FROM events`, OPA intercepts that query during planning (before any data is fetched) and returns a masking rule — an `expression` field in a JSON policy decision — saying: "for this user, email should be replaced with `to_hex(sha256(to_utf8(email)))`." Trino's planner then rewrites the query to `SELECT to_hex(sha256(to_utf8(email))) AS email, event_name FROM events`.

The user gets results, but they never see the raw email address. This happens at the query engine layer, so there's no way to bypass it — even if someone tries a direct query, the OPA policy fires first.

## Implementation Path

**Step 1: Configure OPA column masking in Trino**

In your Trino coordinator's `etc/access-control.properties`, add the column-masking endpoint alongside your existing row-filter endpoint:

```properties
access-control.name=opa
opa.policy.uri=http://opa:8181/v1/data/trino/allow
opa.policy.row-filters-uri=http://opa:8181/v1/data/trino/rowFilters
opa.policy.batch-column-masking-uri=http://opa:8181/v1/data/trino/batchColumnMask
```

Use the **batch endpoint** (`batch-column-masking-uri`), not the single-column one. If your `events` table has 20 columns, the single-column endpoint makes one OPA call per column (20 calls per query). The batch endpoint sends all columns in one request and OPA responds with all masking decisions at once — cutting overhead from 20 calls to 1.

**Step 2: Write OPA Rego rules for column masking**

The `columnMask` Rego rule is the sibling to `rowFilters`. It returns a SQL expression that replaces the column value. Example pattern:

```rego
# Mask email for non-admin users
columnMask contains {"expression": "to_hex(sha256(to_utf8(email)))"} if {
    input.action.resource.column.columnName == "email"
    not admin_user(input.context.identity.user)
}

# Redact user_name entirely for tenant principals
columnMask contains {"expression": "'****'"} if {
    input.action.resource.column.columnName == "user_name"
    tenant_user(input.context.identity.user)
}

# Domain-only email for cohort analysis use case
columnMask contains {"expression": "REGEXP_REPLACE(email, '@.*', '@redacted.com')"} if {
    input.action.resource.column.columnName == "email"
    input.context.identity.user == "analyst-role"
}
```

Your actual rules will depend on how you encode user identity (JWT claims, username prefix, external lookup) and what masking you need per column and role. The external governance document covers the specific Rego syntax for your auth setup.

**Step 3: Important — batch endpoint response format**

The batch endpoint response has a different JSON shape than the single-column endpoint. If you copy Rego from a single-column example, the batch version will silently fail.

Wrong (single-column endpoint):
```json
{"expression": "to_hex(sha256(to_utf8(email)))"}
```

Right (for batch endpoint):
```json
[
  {"index": 0, "viewExpression": {"expression": "to_hex(sha256(to_utf8(email)))"}},
  {"index": 1, "viewExpression": {"expression": "'****'"}}
]
```

The key is `viewExpression`, not `expression`.

**Step 4: Test before rolling out**

1. As a customer principal, run `SELECT email FROM analytics.events LIMIT 1` — you should get back a hashed value, not a raw email.
2. As an internal analyst (if your policy permits), run the same query — you should get the actual email.
3. Check Trino's `EXPLAIN` output as the tenant principal — the injected mask expression appears as a `Filter` / expression node above the table scan. This is where you debug "why is masking not working," not in OPA decision logs.

## Why This Is Better Than Table Duplication

- **One copy of the data.** No sync headaches; the events table grows once.
- **One schema to evolve.** Add a column to events — done. No migrations on a hidden table.
- **Isolation is query-engine-enforced.** Customers cannot bypass masking by running a different query. OPA fires on every `SELECT`, regardless of how the SQL is written.
- **Masking adapts to user.** Different users can have different policies (internal sees raw PII, customers see hashes) without table splits.
- **Composes with row filtering.** Row filters (`rowFilters`) determine which rows a tenant sees; column masks (`columnMask`) determine which values they see within those rows. Both operate simultaneously on every query.
