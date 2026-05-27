# Iter 204 Q1 — OPA Batch Column Masking URI: Override Semantics and Safe Migration

## Answer

Based on your production environment (Trino 467 + OPA), here's the precise behavior of the two column-masking properties and how to safely migrate.

### 1. What `column-masking-uri` does: Per-column HTTP calls

The single-column endpoint makes **one HTTP request per column per query**. When Trino analyzes a query that touches a table, it contacts OPA for each column that appears in the SELECT list (or any other column the query references).

**Latency cost on wide tables:**
- A 40-column table = 40 sequential HTTP round-trips to OPA before query planning even begins.
- On a busy cluster, this becomes a measurable per-query latency tax.
- Each round-trip incurs network serialization, OPA policy evaluation, and deserialization overhead.

**Example flow for `SELECT email, phone, ssn FROM analytics.users`:**
1. Trino POSTs to OPA for `email` → OPA returns mask expression.
2. Trino POSTs to OPA for `phone` → OPA returns mask expression.
3. Trino POSTs to OPA for `ssn` → OPA returns mask expression.
4. Only then does Trino start planning the query.

---

### 2. What `batch-column-masking-uri` does: All columns in one request

The batch endpoint sends **every column for a given table in a single HTTP request**. OPA evaluates the masking policy for all columns at once and returns the full result set in one response.

**Latency benefit:**
- 40-column table = 1 HTTP round-trip instead of 40.
- Eliminates the sequential per-column call chain — Trino constructs a single batch request with all columns, OPA evaluates once, returns all masks.

---

### 3. Semantics: OVERRIDE, not fallback

**Critical distinction:** When you set `opa.policy.batch-column-masking-uri`, it **completely replaces** (overrides) the single-column URI. Trino does NOT call both. The semantics are:

- **Only `column-masking-uri` set**: Trino makes per-column HTTP calls to that endpoint.
- **Only `batch-column-masking-uri` set**: Trino makes batch HTTP calls to that endpoint. The single-column URI is ignored.
- **Both set**: The batch URI **wins**. Trino sends batch requests to the batch endpoint; the single-column URI is NOT called.
- **Both set but batch handler missing in Rego**: Policy evaluation fails or silently skips masking. There is NO fallback to the single-column URI.

This is crucial: adding the batch URI without updating your Rego policy to implement the batch handler will break column masking silently or visibly fail — there is no automatic retry.

---

### 4. Response shape difference — Critical to get right

The two endpoints have **completely different JSON response shapes**. Using the wrong shape silently breaks masking.

**Single-column endpoint (`column-masking-uri`):**
```json
{
  "expression": "to_hex(sha256(to_utf8(email)))"
}
```

OPA returns one object per HTTP call, with a single key: `expression` (the SQL expression to substitute for the column).

**Batch endpoint (`batch-column-masking-uri`):**
```json
[
  {
    "index": 0,
    "viewExpression": {
      "expression": "to_hex(sha256(to_utf8(email)))"
    }
  },
  {
    "index": 1,
    "viewExpression": {
      "expression": "'****'"
    }
  }
]
```

OPA returns an **array**, one entry per input column. Each entry has:
- `index`: The position of the column in the batch request (0-based).
- `viewExpression`: A **nested object** (not `expression` at the top level) containing the mask.

**The silent failure mode:** If you write a batch Rego handler that returns `{"expression": "..."}` instead of `{"index": 0, "viewExpression": {"expression": "..."}}`, Trino will either fail policy evaluation or silently skip the mask — and you may not notice until a customer reports seeing unmasked PII.

---

### 5. Safe migration steps — Masking never accidentally breaks

Follow this sequence to ensure masking stays active during the migration:

**Step 1: Test the batch handler in your Rego policy (offline)**

Write a new batch handler in your Rego bundle that wraps your existing per-column logic. Test it locally with your OPA test suite.

Example Rego pattern (wrapping an existing per-column rule):

```rego
# Existing per-column rule (keep this)
columnMask[column.name] = mask {
    column := input.action.resource.column
    # ... your masking logic here
    mask := {"expression": "to_hex(sha256(to_utf8(column.name)))"}
}

# New batch handler
batchColumnMask = response {
    response := [
        {
            "index": idx,
            "viewExpression": columnMask[input.action.resource.columns[idx].name]
        } |
        idx := range(count(input.action.resource.columns))
    ]
}
```

Deploy this updated Rego to your OPA bundle but do NOT yet set `batch-column-masking-uri` in Trino.

**Step 2: Enable both endpoints in Trino config**

Update `etc/access-control.properties` to set **both** URIs (for now):

```properties
access-control.name=opa
opa.policy.uri=http://opa:8181/v1/data/trino/allow
opa.policy.row-filters-uri=http://opa:8181/v1/data/trino/rowFilters
opa.policy.column-masking-uri=http://opa:8181/v1/data/trino/columnMask
opa.policy.batch-column-masking-uri=http://opa:8181/v1/data/trino/batchColumnMask
```

Restart the Trino coordinator. **Once the batch URI is set, Trino will use it exclusively** — the single-column URI is ignored. Verify that masking still works by running a test query.

**Step 3: Run validation queries on a representative table**

Pick a wide table (20+ columns) with sensitive data. As a user who should see masked columns, run:

```sql
SELECT col1, col2, col3, ... FROM analytics.sensitive_table LIMIT 1;
```

Verify that:
- Sensitive columns are masked (show hashes or redacted values, not raw data).
- All other columns are unmasked.
- The query completes without errors.

Check the OPA decision log to confirm the batch handler was called (look for a single `/batchColumnMask` evaluation per query, not 20+ `/columnMask` evaluations).

**Step 4: Remove the single-column URI from config**

Once you've confirmed batch masking works, remove `opa.policy.column-masking-uri` from `etc/access-control.properties`. Keep only:

```properties
access-control.name=opa
opa.policy.uri=http://opa:8181/v1/data/trino/allow
opa.policy.row-filters-uri=http://opa:8181/v1/data/trino/rowFilters
opa.policy.batch-column-masking-uri=http://opa:8181/v1/data/trino/batchColumnMask
```

Restart and re-run your validation queries. Masking should still work identically.

**Why this order is safe:** Setting the batch URI while the single-column URI is still configured causes Trino to use batch. If the batch handler has a bug, you catch it in step 3. Removing the single-column URI only after batch is confirmed working ensures there's no silent fallback to a broken configuration.

---

### Key decision points

1. **Do I need the batch endpoint?** Yes, if your typical tables have >15–20 columns. Below that, the per-column latency overhead is negligible. Above 30, batch is nearly mandatory on a busy cluster.
2. **Can I test batch without restarting Trino?** No. The URIs are loaded at coordinator startup. Plan for a brief maintenance window and test the upgrade path first in a staging environment.
