# Answer to Q1: Column Masking Stopped Working After Adding Batch Masking Endpoint (Iter 317)

The problem is almost certainly a **mismatch between your batch endpoint URI and the Rego rule name** — a silent-failure trap that causes masking to fail open (raw values returned) with no error logged.

## The root cause

When you added the batch masking endpoint (`opa.policy.batch-column-masking-uri`), Trino now calls the batch endpoint for column masking decisions. But the batch endpoint requires a different Rego rule name than the single-column endpoint:

| Endpoint config property | Rego rule name | Response shape |
|---|---|---|
| `column-masking-uri` | `columnMask` | `{"expression": "..."}` |
| `batch-column-masking-uri` | `batchColumnMasks` (plural!) | `[{"index": i, "viewExpression": {"expression": "..."}}]` |

Your existing Rego rule is named `columnMask`. When Trino calls the batch endpoint and looks for `batchColumnMasks`, OPA finds no matching rule, returns an empty decision, and Trino interprets that as "no mask configured" — so it passes through the raw email. No error is raised because an empty policy decision is treated as valid.

**This is the worst-case failure mode for security: the feature fails open, and you only discover it when someone audits the data.**

## Why this breaks silently

When both `column-masking-uri` and `batch-column-masking-uri` are configured, `batch-column-masking-uri` takes precedence and `column-masking-uri` is silently ignored. Trino uses the batch endpoint exclusively once it's configured. Your existing `columnMask` rule — which was working fine before — is now never called.

## The two patterns (side-by-side)

**Single-column endpoint:**
```
Config: opa.policy.column-masking-uri=http://opa:8181/v1/data/trino/columnMask
Rego rule: columnMask
Response: {"expression": "to_hex(sha256(to_utf8(email)))"}
Cost: 1 HTTP call per column
```

**Batch endpoint:**
```
Config: opa.policy.batch-column-masking-uri=http://opa:8181/v1/data/trino/batchColumnMask
Rego rule: batchColumnMasks (plural!)
Response: [{"index": 0, "viewExpression": {"expression": "to_hex(sha256(to_utf8(email)))"}}]
Cost: 1 HTTP call per table
```

Key differences in the batch response:
1. It's an **array** (not a single object)
2. Each entry has **`"index": i`** (the column's position in the request)
3. The expression is nested under **`"viewExpression"`**, not directly at the top level

## How to fix it

**Option A: Use only the batch endpoint (recommended for production)**

1. Keep `batch-column-masking-uri` in your Trino config
2. Remove `column-masking-uri` to avoid confusion
3. Rename your Rego rule from `columnMask` to `batchColumnMasks` and update the response shape:

```rego
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

**Option B: Revert to single-column endpoint**

Remove `batch-column-masking-uri` from your Trino config. Your existing `columnMask` rule will work again. You can add the batch endpoint properly later when you've updated the Rego.

## How to detect this in CI

Add an integration test that asserts masking is actually working:

```sql
-- As a non-admin principal:
SELECT LENGTH(email) AS len, email LIKE '%@%' AS looks_like_email
FROM analytics.events LIMIT 1;
-- Expected: len = 64, looks_like_email = false
-- If len < 64 or looks_like_email = true: masking is broken
```

## The four-configuration truth table

| Endpoint configured | Rule you wrote | Result |
|---|---|---|
| `column-masking-uri` | `columnMask` | Masking works ✓ |
| `batch-column-masking-uri` | `batchColumnMasks` + `viewExpression` array | Masking works ✓ |
| `batch-column-masking-uri` | `columnMask` | Silent failure — no masking, no error ✗ |
| `column-masking-uri` | `batchColumnMasks` | Silent failure — no masking, no error ✗ |
| Both URIs configured | Either rule | batch-column-masking-uri takes precedence; column-masking-uri silently ignored ✗ |
