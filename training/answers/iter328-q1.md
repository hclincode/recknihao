# Answer to Q1: OPA Row-Level Security and Column Masking Composition (Iter 328)

Your row-level security and column masking do **not interfere with each other** — they compose independently and both apply to the same query. Neither cancels the other, and OPA does not short-circuit.

## They Both Apply, in Sequence, at Query Analysis Time

Both row filters and column masking happen **once per query, during the analysis phase on the Trino coordinator**, before the query plan is sent to workers. Here is what happens:

1. **Row filter evaluates** — OPA returns a WHERE expression like `tenant_id = 'acme'`, Trino injects it into the query plan.
2. **Column masking evaluates** — OPA returns a SQL expression replacing each sensitive column (e.g., `email` → `to_hex(sha256(to_utf8(email)))`), Trino rewrites the column reference.
3. **Both are applied** — the final query plan has both the row filter AND the column masks before execution begins.

## Order: Row Filter First, Column Mask Second

When a non-admin user queries:

```sql
SELECT email, tenant_id, event_type FROM analytics.events;
```

Trino's analysis phase builds a plan equivalent to:

```sql
SELECT to_hex(sha256(to_utf8(email))) AS email, tenant_id, event_type
FROM analytics.events
WHERE tenant_id = 'acme';
```

Both transformations are in the plan. Row filter narrows which rows survive; column masking rewrites values in those surviving rows.

## No Short-Circuiting

OPA does not evaluate one rule and skip the other. During analysis, Trino consults OPA for:
- Allow/deny permission
- Row filters for this table
- Column masks for these columns

All constraints returned are applied. There is no path where a row filter's success causes column masking to be skipped.

## A Non-Admin Cannot See Unmasked Values via the Row Filter

Your worry that row-filter narrowing could bypass column masking is not a real risk:

1. **Row filters do not exempt column masks.** A row surviving the row filter does not escape the mask. The mask is applied to every row in the result set, regardless of how many rows the filter lets through.
2. **The mask is substituted in the plan.** Trino literally replaces the column reference with the masked expression before execution. There is no code path where a row filter's success causes a column mask to be skipped.

## Concrete Example: Both Applied to the Same Query

Setup:
- Row filter: user `alice` can only see rows where `tenant_id = 'alice'`
- Column mask: non-admin users see `email` and `ssn` as hashes

Alice runs:
```sql
SELECT user_id, email, ssn, created_at FROM analytics.users;
```

Trino builds the plan:
```sql
SELECT
  user_id,
  to_hex(sha256(to_utf8(email))) AS email,
  to_hex(sha256(to_utf8(ssn))) AS ssn,
  created_at
FROM analytics.users
WHERE tenant_id = 'alice'
```

Alice sees only her tenant's rows, with email and SSN hashed. Both rules applied, no conflict.

## Configuration

Both URIs configured in `etc/access-control.properties`:

```properties
access-control.name=opa
opa.policy.uri=http://opa:8181/v1/data/trino/allow
opa.policy.row-filters-uri=http://opa:8181/v1/data/trino/rowFilters
opa.policy.batch-column-masking-uri=http://opa:8181/v1/data/trino/batchColumnMask
```

Write both Rego rules independently — they operate at different levels and don't reference each other:

```rego
package trino

import future.keywords.contains
import future.keywords.if

# Row filter — which rows can this user see?
rowFilters contains {"expression": expr} if {
    tenant_id := principal_to_tenant[input.context.identity.user]
    expr := sprintf("tenant_id = '%s'", [tenant_id])
}

# Column masking — which columns need masking? (batch form)
batchColumnMasks contains {"index": i, "viewExpression": {"expression": expr}} if {
    some i
    resource := input.action.filterResources[i]
    not "pii-cleared" in input.context.identity.groups
    resource.column.columnName == "email"
    expr := "to_hex(sha256(to_utf8(email)))"
}

batchColumnMasks contains {"index": i, "viewExpression": {"expression": expr}} if {
    some i
    resource := input.action.filterResources[i]
    not "pii-cleared" in input.context.identity.groups
    resource.column.columnName == "ssn"
    expr := "to_hex(sha256(to_utf8(ssn)))"
}
```

Both rules fire during the same query analysis phase. No interaction between them.

## Important: Restart Trino After Config Changes

If you add `opa.policy.batch-column-masking-uri` to `etc/access-control.properties`, restart the Trino coordinator — the file is read at startup only, not hot-reloaded. Without the restart, column masking silently won't apply and you might incorrectly think the two features conflict.

## Bottom Line

Row-level security and column masking compose independently. Both apply to every query where triggered. OPA does not short-circuit, and neither rule cancels the other. Your only real concerns are configuration correctness (wire both URIs) and testing (CI tests that verify both constraints are enforced together on the same query). They do not interfere.
