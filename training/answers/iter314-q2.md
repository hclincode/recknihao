# Answer to Q2: OPA Column Masking Silently Not Working — batchColumnMasks vs columnMask (Iter 314)

You've hit the exact silent-failure trap for column masking: **the batch endpoint and single-column endpoint require different Rego rule names, and Trino doesn't error when it can't find the rule — it just silently returns the raw column.**

## What's Happening

You configured `batch-column-masking-uri`, but your Rego rule is named `columnMask`. When Trino tries to fetch the masking decision from OPA, it calls the batch endpoint and looks for a rule named `batchColumnMasks` (plural). OPA evaluates your policy, finds no `batchColumnMasks` rule, returns an empty decision, and Trino interprets that as "no mask configured" — so it passes through the raw email. No error is raised because an empty policy decision is treated as valid.

**The fix:** rename your Rego rule from `columnMask` to `batchColumnMasks` (plural).

## The Two Endpoints and Their Required Rule Names

| Endpoint config property | OPA URI path | Rego rule name | Response shape |
|---|---|---|---|
| `column-masking-uri` | `.../columnMask` | `columnMask` | Single object: `{"expression": "..."}` |
| `batch-column-masking-uri` | `.../batchColumnMask` | `batchColumnMasks` (plural!) | Array: `[{"index": i, "viewExpression": {"expression": "..."}}]` |

The batch endpoint makes **one OPA call per table** (all columns at once, instead of one call per column). This is why it's recommended for tables with many columns — cuts 20+ sequential OPA calls down to 1.

## Two Different Places to Get Tripped Up

**Trap 1: Wrong rule name** (what you have now)
- You configured `batch-column-masking-uri` but wrote `columnMask contains {...}` in Rego
- OPA can't find `batchColumnMasks`, returns empty decision, no masking applied, no error

**Trap 2: Wrong response shape** (a different silent failure)
- Even if you rename to `batchColumnMasks`, the response shape is different from the single-column endpoint
- Batch requires `{"index": i, "viewExpression": {"expression": "..."}}` — **not** `{"expression": "..."}`
- Wrong shape → OPA evaluates successfully, Trino reads the response, doesn't find `viewExpression`, treats it as no mask

## Correct Batch Rego (what your rule should look like)

```rego
package trino

import future.keywords.contains
import future.keywords.if

# Batch column masking — one call per table, all columns at once
batchColumnMasks contains mask if {
    some i
    resource := input.action.filterResources[i]
    resource.column.columnName == "email"
    not admin_user(input.context.identity.user)
    mask := {
        "index": i,
        "viewExpression": {
            "expression": "to_hex(sha256(to_utf8(email)))"
        }
    }
}
```

Key differences from the single-column `columnMask` rule:
1. Rule is named **`batchColumnMasks`** (plural)
2. Must iterate `input.action.filterResources` to process each column OPA received
3. Each mask object has **`"index": i`** (which column position in the request) and **`"viewExpression"`** (not `"expression"`)

## Correct Single-Column Rego (for comparison)

```rego
# Single-column masking — one call per column
columnMask := {"expression": "to_hex(sha256(to_utf8(email)))"} if {
    input.action.resource.column.columnName == "email"
    not admin_user(input.context.identity.user)
}
```

## How to Detect This in CI

Add an integration test that asserts the masking is actually working:

```sql
-- As a non-admin principal:
SELECT email FROM analytics.events LIMIT 1;
-- Must NOT return a raw email address (e.g., user@example.com)
-- Must return a hex hash (40 chars, all hex digits)

-- Verify length and format:
SELECT LENGTH(email) AS len, email LIKE '%@%' AS looks_like_email
FROM analytics.events LIMIT 1;
-- Expected: len = 64, looks_like_email = false
```

If this test fails, something is misconfigured (wrong rule name, wrong response shape, or the OPA decision log will show the policy evaluated but returned nothing matching).

## Summary of the Four-Configuration Truth Table

| Endpoint configured | Rule you wrote | Result |
|---|---|---|
| `column-masking-uri` | `columnMask` | Masking works ✓ |
| `batch-column-masking-uri` | `batchColumnMasks` + `viewExpression` array | Masking works ✓ |
| `batch-column-masking-uri` | `columnMask` | **Silent failure — no masking, no error** ✗ |
| `column-masking-uri` | `batchColumnMasks` | **Silent failure — no masking, no error** ✗ |
