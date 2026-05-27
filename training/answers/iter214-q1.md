# Iter 214 Q1 — OPA batch-column-masking-uri: Response Shape and Override Semantics

## Answer

## Batch Column Masking Endpoint: Response Shape, Configuration, and Fallback Behavior

### 1. Response Shape — How It Differs from `batched-uri`

The `batch-column-masking-uri` endpoint **returns a shape similar to but not identical from** `batched-uri` (table filtering). Both use the same **sparse, index-based pattern**, but the contents differ:

**Input**: OPA receives an array in `action.filterResources` containing all columns of a single table:
```json
{
  "input": {
    "action": {
      "operation": "GetColumnMask",
      "filterResources": [
        {"column": {"catalogName": "app_pg", "schemaName": "public", "tableName": "users", "columnName": "email"}},
        {"column": {"catalogName": "app_pg", "schemaName": "public", "tableName": "users", "columnName": "ssn"}},
        {"column": {"catalogName": "app_pg", "schemaName": "public", "tableName": "users", "columnName": "username"}}
      ]
    },
    "context": {
      "identity": {"user": "analyst-alice", "groups": ["analysts"]},
      "queryId": "20260526_142315_00042_xyz"
    }
  }
}
```

**Output**: A **sparse array** of `{index, viewExpression}` objects — **OPA returns only columns that need masking**:
```json
[
  {"index": 0, "viewExpression": {"expression": "sha256(CAST(email AS VARCHAR))"}},
  {"index": 1, "viewExpression": {"expression": "CONCAT('***-**-', RIGHT(CAST(ssn AS VARCHAR), 4))"}}
]
```

Note that `index: 2` (username) is **omitted entirely** — this means "no masking for this column, read as-is."

**Key difference from `batched-uri`**:
- `batched-uri` returns indices of **permitted** resources (used for filtering which tables/columns to show).
- `batch-column-masking-uri` returns indices of columns that **require masking**, plus the SQL mask expression for each.
- Both are sparse (omit entries where no action is needed).

### 2. Mutual Exclusivity — Can They Both Be Configured?

**No, they are mutually exclusive for column masking only.** You **cannot use both `opa.policy.column-masking-uri` and `opa.policy.batch-column-masking-uri` at the same time** — if both are set, Trino silently ignores `column-masking-uri` and uses only the batch URI.

However, the two batch URIs (`opa.policy.batched-uri` and `opa.policy.batch-column-masking-uri`) cover **different operation categories** and **should both be configured in production**:

| Config Property | Covers | Input | Output |
|---|---|---|---|
| `opa.policy.batched-uri` | Filter operations (`FilterTables`, `FilterSchemas`, `FilterColumns`, etc.) | Array of tables/schemas/columns to filter | Sparse array of zero-based **indices** of permitted candidates |
| `opa.policy.batch-column-masking-uri` | Column masking (`GetColumnMask`) for all columns on one table | Array of all columns on a table | Sparse array of `{index, viewExpression}` objects for masked columns |

### 3. Practical Configuration Guidance

**Why enable batch column masking:** On a 40-column table, the non-batch `column-masking-uri` makes 40 separate sequential OPA calls per query. The `batch-column-masking-uri` collapses this to 1 call per table, eliminating 39 HTTP round-trips (1–20ms each on a separate OPA service).

**Recommended production configuration:**
```properties
access-control.name=opa
opa.policy.uri=http://opa-svc:8181/v1/data/trino/allow                                    # mandatory, single-resource baseline
opa.policy.batched-uri=http://opa-svc:8181/v1/data/trino/batchAllow                       # optional, filter-list optimization
opa.policy.batch-column-masking-uri=http://opa-svc:8181/v1/data/trino/batchColumnMask     # REPLACE per-column URI with this
# DO NOT configure opa.policy.column-masking-uri — the batch URI overrides it
opa.policy.row-filters-uri=http://opa-svc:8181/v1/data/trino/rowFilters
```

**Rollout sequence**: Enable `batch-column-masking-uri` first (bigger latency win on wide tables), then `batched-uri` (improves `SHOW SCHEMAS`/`SHOW TABLES` planning).

**Rego handler pattern** (in your OPA policy): Index into `input.action.filterResources[i]` and return the index plus mask expression for columns that need masking. The Rego pattern is identical to the `batched-uri` filter handler — just return `{index, viewExpression}` instead of bare indices.
