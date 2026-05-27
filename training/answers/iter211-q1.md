# Iter 211 Q1 — OPA batched-uri: Complement Not Override, Filter-List Operations Only

## Answer

**Your understanding is incorrect on the core point — here's the accurate behavior:**

**`opa.policy.batched-uri` does NOT take over from `opa.policy.uri`. It COMPLEMENTS it.** Both URIs must be configured. They serve different categories of operations, not "batch vs. single mode of the same operation set."

---

### What each endpoint handles

**`opa.policy.uri`** (REQUIRED, always-on) — single-resource operations like `CreateTable`, `DeleteFromTable`, `ExecuteQuery`, `AccessCatalog`, `RenameTable`. These always make one OPA call to the single-call endpoint, regardless of whether batched-uri is configured.

**`opa.policy.batched-uri`** (OPTIONAL, additive) — **filter-list operations only**: `FilterCatalogs`, `FilterSchemas`, `FilterTables`, `FilterColumns`, `FilterViews`. This is where the batching happens. Without it configured, Trino falls back to sending one call to `opa.policy.uri` for each candidate object. With it configured, Trino collapses N per-object calls into one HTTP request carrying all N candidates.

**What you're experiencing with 200 catalogs**: When a user lists catalogs, Trino asks OPA "which of these 200 candidates can this user see?" Without `batched-uri`, that's 200 separate HTTP calls to `opa.policy.uri`. With `batched-uri`, it's 1 call. Same collapsing happens for schema listings, table listings, and column listings.

---

### Your existing Rego policy stays as-is — you ADD a batch handler

You don't replace your existing policy. You add a new batch handler rule to the same package. The pattern uses a `batch` rule with the `some i` quantifier to index into the candidate array:

```rego
batch contains i if {
    some i
    resource := input.action.filterResources[i]
    # your per-resource logic here
    tenant := split(input.context.identity.user, "--")[0]
    resource.table.schemaName == tenant
}
```

---

### The input/output contract

**Input**: Trino sends `action.filterResources` — an array of candidate resource objects:

```json
{
  "action": {
    "operation": "FilterTables",
    "filterResources": [
      {"table": {"catalogName": "iceberg", "schemaName": "analytics", "tableName": "events"}},
      {"table": {"catalogName": "iceberg", "schemaName": "analytics", "tableName": "audit_log"}},
      {"table": {"catalogName": "app_pg", "schemaName": "public", "tableName": "tenants"}}
    ]
  },
  "context": {"identity": {"user": "acme--alice", "groups": []}}
}
```

**Output**: OPA returns an array of zero-based indices — the positions in `filterResources` the user is allowed to see:

```json
{"result": [0, 2]}
```

Index 0 = `events` allowed, index 2 = `tenants` allowed. Index 1 (`audit_log`) is absent — filtered out.

---

### What the batch endpoint covers vs what it doesn't

| Operation type | Endpoint used |
|---|---|
| `FilterCatalogs`, `FilterSchemas`, `FilterTables`, `FilterColumns`, `FilterViews` | `batched-uri` (when configured) |
| `CreateTable`, `DeleteFromTable`, `ExecuteQuery`, `RenameTable`, `AccessCatalog` | `uri` always (single-resource, no list to batch) |
| Single-table `SelectFromColumns` | `uri` always |

---

### Fallback behavior — no failure if batch handler is missing

If you don't configure `batched-uri`, Trino falls back gracefully to one per-candidate call to `opa.policy.uri`. There is no error. The batched endpoint is a **performance optimization**, not a required feature — the single-call endpoint is always the baseline.

---

### Configuration

```properties
access-control.name=opa
opa.policy.uri=http://opa:8181/v1/data/trino/allow              # REQUIRED — single-resource ops
opa.policy.batched-uri=http://opa:8181/v1/data/trino/batchAllow # OPTIONAL — filter-list ops only
```

For your 200-catalog case, enabling `batched-uri` will cut catalog list calls from 200 per query to 1, which should significantly reduce coordinator CPU from authorization round-trips. Same benefit applies to schema and table listing.
