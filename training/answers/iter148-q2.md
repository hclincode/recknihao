# Iter 148 Q2 — OPA Column Masking with Trino

## Answer

Your team is correct — OPA can enforce column-level masking at the query level. But it works differently than a simple block: OPA rewrites specific column expressions at query analysis time, and yes, Trino returns different column values to different users for the same query.

### How OPA column masking works

OPA does not block access entirely. Instead it uses **column-masking mode** that works like this:

1. **At query analysis time** — after Trino parses your SQL but before executing it — Trino asks OPA: "user X is trying to read column `email` from table `analytics.users` — what should I return?"

2. **OPA returns a SQL expression** instead of a yes/no. For example: `"to_hex(sha256(to_utf8(email)))"`.

3. **Trino transparently rewrites the query** to substitute that expression. So when a customer analyst runs:
   ```sql
   SELECT user_id, email, billing_zip FROM analytics.users;
   ```
   Trino actually executes:
   ```sql
   SELECT user_id,
          to_hex(sha256(to_utf8(email))) AS email,
          NULL AS billing_zip
   FROM analytics.users;
   ```
   While when your internal CS team runs the same query, OPA returns no masking rule, and Trino executes it as-is with the real values.

**Same query text, different results** — determined by who runs it (the JWT-authenticated principal) and what OPA's policy says about their access.

### Configuration on your production stack

In `/etc/access-control.properties` on the Trino coordinator:

```properties
access-control.name=opa
opa.policy.uri=http://opa:8181/v1/data/trino/allow
opa.policy.row-filters-uri=http://opa:8181/v1/data/trino/rowFilters
opa.policy.column-masking-uri=http://opa:8181/v1/data/trino/columnMask
```

The `column-masking-uri` endpoint is where OPA returns the masking expressions for each column access decision.

### What OPA returns for each column

OPA returns JSON like these examples:

```json
{ "expression": "to_hex(sha256(to_utf8(email)))" }
```
```json
{ "expression": "NULL" }
```
```json
{ "expression": "'****'" }
```

For your specific case:
- `email` → hash (`to_hex(sha256(to_utf8(email)))`) for customers, no masking for CS team
- `billing_zip` → `NULL` for customers, no masking for CS team
- Hashed phone number → already hashed, likely no additional masking needed

### Two critical gotchas

**1. Constant masks break GROUP BY and JOINs.** If you mask `email` to a constant like `'****'`, then `SELECT email, COUNT(*) FROM users GROUP BY email` collapses all rows into a single group — every masked email looks identical. Use a **deterministic hash** instead (`to_hex(sha256(to_utf8(email)))`): the same input always produces the same output, so grouping and joining work correctly while PII stays hidden.

**2. OPA receives the Trino username, not JWT claims.** Your production stack uses JWT for auth, but OPA only receives the username that Trino's JWT authenticator extracted — not the raw JWT claims. This means your JWT issuance or username convention must encode enough information for OPA to determine whether to mask. Common patterns:
- Encode the principal type in the username: `customer-acme-svc` vs `cs-team-user`, then OPA checks the prefix.
- Maintain a lookup table in an OPA data bundle: `{"customer-acme-svc": "customer", "alice@internal": "internal"}`.

### Why this is better than views

You could solve this with Trino views — one view per audience — but column masking has advantages:
- **One base table queried by everyone** — no view-maintenance burden
- **Policy hot-reloads** — update the OPA Rego bundle and new rules are live in seconds without restarting Trino
- **No view sprawl** — no need for `analytics.users_for_customers` and `analytics.users_for_cs_team` to stay in sync

### Row-level filtering (related but separate)

If you also need to hide entire rows from customers (e.g., hide rows for deleted accounts), that uses a separate OPA feature: **row filters**. OPA injects a WHERE clause (`AND tenant_id = 'acme'`) rather than rewriting column expressions. It uses the same OPA infrastructure (`opa.policy.row-filters-uri`) but is configured separately from column masking. Both can be active simultaneously.

### What you need to do next

1. **Write the OPA Rego rules** — these live in your governance policy repo, not in Trino config. The rules define: for which principal types, which columns, what expression to return.

2. **Configure the three OPA endpoints** in `access-control.properties` on the coordinator (shown above).

3. **Test with each principal type**:
   ```sql
   -- As a customer principal:
   SELECT email FROM analytics.users LIMIT 1;
   -- Should return a hash, not the real email

   -- As an internal principal:
   SELECT email FROM analytics.users LIMIT 1;
   -- Should return the real email
   ```

4. **Handle GROUP BY with hashed columns** — verify that grouping on a masked column produces the right cardinality. A deterministic hash groups correctly; a constant mask does not.

### Summary

| Mechanism | What OPA does | When to use |
|---|---|---|
| Column masking | Rewrites specific column expressions at analysis time | Return different values (hash, NULL) per principal |
| Row filtering | Injects a WHERE clause at analysis time | Hide entire rows from certain principals |
| Allow/deny | Returns boolean allow/deny | Block access to tables or schemas entirely |

OPA column masking is transparent SQL rewriting — the same query returns different data depending on who runs it. This is the right tool for your use case.
