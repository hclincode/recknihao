# Answer to Q1: Column Masking in Trino + OPA (Iter 327)

Yes, Trino and OPA absolutely support column-level masking of sensitive data based on who's querying. This is exactly what you're describing — hiding credit card and email values from non-admin users while letting admins see the real data.

## How it works at a high level

OPA doesn't mask data in the database. Instead, it tells Trino to **rewrite the column** in the query before execution. When a non-admin queries a table, OPA returns a SQL expression (like `CONCAT(SUBSTR(card_number, 1, 4), '****')` for credit cards), and Trino substitutes that expression for the column in the query plan. The database returns the masked value instead of the raw one. Admins get a different policy decision from OPA that leaves the column untouched.

## Configuration in access-control.properties

Add column-masking URIs to the Trino coordinator's `access-control.properties`:

```properties
access-control.name=opa
opa.policy.uri=http://opa:8181/v1/data/trino/allow
opa.policy.row-filters-uri=http://opa:8181/v1/data/trino/rowFilters
opa.policy.column-masking-uri=http://opa:8181/v1/data/trino/columnMask
# OR for better performance with wide tables:
opa.policy.batch-column-masking-uri=http://opa:8181/v1/data/trino/batchColumnMask
```

Use one or the other, not both at the same time.

## The two patterns: single-column vs batch

### Pattern A: Single-column endpoint (one HTTP call per column)

Use for narrow tables (under ~15 columns).

**What happens:** Trino makes one HTTP call to OPA for each column you reference. `SELECT card_number, email FROM users` = two separate OPA calls.

**OPA response shape:**
```json
{"expression": "CONCAT(SUBSTR(card_number, 1, 4), '****')"}
```

**Rego rule — name is `columnMask` (singular):**
```rego
package trino

columnMask := {"expression": "CONCAT(SUBSTR(card_number, 1, 4), '****')"} if {
    input.action.resource.column.columnName == "card_number"
    not "admin" in input.context.identity.groups
}

columnMask := {"expression": "to_hex(sha256(to_utf8(email)))"} if {
    input.action.resource.column.columnName == "email"
    not "admin" in input.context.identity.groups
}
# If no rule matches (user is admin), OPA returns null and Trino leaves the column unmasked.
```

**Performance cost:** One round-trip to OPA per column referenced. A query with 40 columns = 40 OPA calls before planning starts.

### Pattern B: Batch endpoint (one HTTP call per table, all columns at once)

Use for wide tables (15+ columns) — recommended for most production SaaS setups.

**What happens:** Trino makes one HTTP call to OPA per table, sending all columns in a single request.

**OPA response shape — critical difference:** Array with one entry per masked column:
```json
[
  {"index": 0, "viewExpression": {"expression": "CONCAT(SUBSTR(card_number, 1, 4), '****')"}},
  {"index": 1, "viewExpression": {"expression": "to_hex(sha256(to_utf8(email)))"}}
]
```

Note: the outer key is `viewExpression`, NOT `expression`. Getting this wrong causes silent failure (raw column returned with no error).

**Rego rule — name is `batchColumnMasks` (plural):**
```rego
package trino

import future.keywords.contains
import future.keywords.if

batchColumnMasks contains {"index": i, "viewExpression": {"expression": expr}} if {
    some i
    resource := input.action.filterResources[i]
    resource.column.columnName == "card_number"
    not "admin" in input.context.identity.groups
    expr := "CONCAT(SUBSTR(card_number, 1, 4), '****')"
}

batchColumnMasks contains {"index": i, "viewExpression": {"expression": expr}} if {
    some i
    resource := input.action.filterResources[i]
    resource.column.columnName == "email"
    not "admin" in input.context.identity.groups
    expr := "to_hex(sha256(to_utf8(email)))"
}
```

Columns whose index doesn't appear in the returned array are left unmasked.

**Performance cost:** One round-trip to OPA per table accessed, regardless of column count.

## Real SQL masking expressions

```
Credit card — first four digits only:
  CONCAT(SUBSTR(card_number, 1, 4), '****')

Email — hash (non-reversible):
  to_hex(sha256(to_utf8(email)))

Email — keep domain, mask username:
  CONCAT(SUBSTR(email, 1, 1), '****@', SUBSTR(email, STRPOS(email, '@') + 1))

Phone — area code only:
  CONCAT(SUBSTR(phone, 1, 3), '-****')

SSN — last four digits only:
  CONCAT('***-**-', SUBSTR(ssn, 8, 4))
```

## The silent-failure trap

If you wire up the wrong Rego rule name, **nothing errors** — the raw column is returned silently.

| Endpoint configured | Rego rule name | Result |
|---|---|---|
| `column-masking-uri` | `columnMask` | ✓ Works |
| `column-masking-uri` | `batchColumnMasks` | ✗ Silent failure — raw column |
| `batch-column-masking-uri` | `batchColumnMasks` | ✓ Works |
| `batch-column-masking-uri` | `columnMask` | ✗ Silent failure — raw column |

**Catch this in CI:** Write a test that queries `SELECT card_number FROM payments` as a non-admin user and asserts the returned value is masked (ends in `****`). If it returns the raw card number, the rule name is misconfigured.

## How Trino rewrites the query

When an analyst runs `SELECT card_number, amount FROM payments`, Trino intercepts it at planning time. OPA returns the masking expression. Trino internally rewrites to:

```sql
SELECT CONCAT(SUBSTR(card_number, 1, 4), '****') AS card_number, amount FROM payments
```

The analyst sees `'4532****'`. Admins' queries run unchanged.

## Performance summary

- **Single-column endpoint:** One OPA call per column — 40 columns = 40 sequential round-trips = 400–2000ms added latency per query on a remote OPA service. Only use on narrow tables.
- **Batch endpoint:** One OPA call per table — 40 columns costs the same as 5 columns. Use for wide tables.

Combined with OPA as a sidecar (per the row-filter guidance), batch column masking adds <5ms overhead per query even on wide tables.

## Identity context

OPA receives the user's identity as `input.context.identity` with `{"user": "...", "groups": [...]}`. Use `not "admin" in input.context.identity.groups` in your Rego to apply masking to non-admins only.

## Next step for your production stack

Your Trino 467 with OPA: use `batch-column-masking-uri` for the `events` table (it's wide). Wire up Rego with rule name `batchColumnMasks` (plural), structure the response with `viewExpression` → `expression` keys, and test masking in CI before rolling out. The masking applies automatically on top of your existing row-filter setup — no conflict.
