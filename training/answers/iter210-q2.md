# Iter 210 Q2 — OPA Batch Endpoint: batched-uri vs row-filters-uri, and What Changes in Rego

## Answer

The batch endpoint is a critical optimization for reducing OPA latency when you're running queries that touch many resources. Let me break down what it does, how it differs from `row-filters-uri`, and what you need to change.

---

### What `opa.policy.batched-uri` actually does

When you enable `opa.policy.batched-uri`, Trino **groups all the non-masking authorization checks for a single query into one HTTP request to OPA**, instead of making one HTTP call per resource. The operations batched include `FilterCatalogs`, `FilterSchemas`, `FilterTables`, `SelectFromColumns` (allow/deny), `CreateTable`, `DeleteFromTable`, and others.

Without the batch endpoint, Trino makes a separate HTTP call to OPA for every one of these operations. To make this concrete: if a single query checks access to 3 catalogs, 5 schemas, and 10 tables, that's 18 separate HTTP round-trips. With the batch endpoint, all 18 go into one request — 1 HTTP call instead of 18. On a separate OPA service at ~10ms per call, that's the difference between 180ms and 10ms of OPA latency per query analysis phase.

---

### How it differs from `opa.policy.row-filters-uri`

These are completely different features:

- **`opa.policy.row-filters-uri`**: Row-level filtering — OPA returns a WHERE clause fragment that Trino injects into the query (e.g., `tenant_id = 'acme'`). One call per table being row-filtered.
- **`opa.policy.batched-uri`**: General authorization batching — batches all access-control decisions (can this user SELECT from this table? can they see this catalog?) into one call.
- **`opa.policy.batch-column-masking-uri`**: Separately batches column-masking decisions.

They can and should all be configured together; they operate on different types of checks.

---

### Which query types benefit most

Your instinct about federated queries is correct. Queries that touch **many tables, schemas, or catalogs** benefit most:

- **Cross-catalog federated queries** (Iceberg + Postgres in the same query) — these trigger authorization checks against both catalogs' tables and schemas
- **Dashboard queries listing metadata** (SHOW CATALOGS, SHOW SCHEMAS, SHOW TABLES) — trigger FilterCatalogs, FilterSchemas, FilterTables for every visible resource
- **Wide-table queries with column masking** — combine batch-masking calls AND batch-uri calls for structural checks

A simple single-table SELECT won't see much gain. A complex analytics query touching 20+ objects across multiple catalogs will see significant latency reduction — which is exactly your federated cross-catalog workload.

---

### What changes in your Rego policies

**This is the critical part.** The batch endpoint requires your Rego policy to handle a different request/response format.

The key point:

> **`batched-uri` completely overrides (not complements) the single-call `uri` for the operations it covers. If you configure `opa.policy.batched-uri` but your OPA bundle doesn't implement the batch handler, those authorization checks fail rather than silently falling back to the single-call endpoint.**

Your Rego policy needs to implement a handler at the batch endpoint. The batch handler receives all the authorization checks for a query in one request and must return decisions for all of them at once. This means:

1. Write a separate Rego rule that iterates over the batch of access-check inputs
2. Return decisions in the format OPA and Trino expect for batched responses (plural, not singular)
3. Test thoroughly — if your rule returns the single-call shape, it will fail or produce a policy-eval error

---

### Configuration

In `etc/access-control.properties`:

```properties
access-control.name=opa
opa.policy.uri=http://opa:8181/v1/data/trino/allow                          # single-call fallback
opa.policy.batched-uri=http://opa:8181/v1/data/trino/batchAllow             # batches all non-masking checks
opa.policy.row-filters-uri=http://opa:8181/v1/data/trino/rowFilters
opa.policy.column-masking-uri=http://opa:8181/v1/data/trino/columnMask
opa.policy.batch-column-masking-uri=http://opa:8181/v1/data/trino/batchColumnMask
```

Once enabled, Trino will:
- Send all non-masking authorization checks to `batchAllow`
- Send column-masking checks to `batchColumnMask`
- Use the single-call `uri` only for operations without a batch variant

---

### Downsides and caveats

1. **No automatic fallback**: Once you enable the batch endpoint, you must have a working batch handler in your OPA bundle. No fallback to the single-call endpoint if the batch handler is missing — queries fail at analysis with authorization errors.

2. **More complex to test**: Batch endpoints require crafting full batch requests for CI testing, not just single authorization queries.

3. **Migration required**: If your team's existing OPA bundle only has single-call handlers, enabling `batched-uri` is not a one-line config change — you need to add the batch handler to your Rego code and test it in staging first.

---

### Next steps

1. **Check if your OPA bundle already has batch handlers.** If your policy implements `batchAllow` (and `batchColumnMask`), you can enable batching with a config change. If not, write the batch handlers first.
2. **Test in staging.** Enable batching, run typical dashboard and federated queries, monitor OPA decision logs.
3. **Monitor coordinator CPU.** With fewer round-trips per query analysis, coordinator OPA-path CPU should drop — which is exactly what you're trying to solve.
