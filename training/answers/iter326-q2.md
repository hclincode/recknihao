# Answer to Q2: OPA row-level security — why batched-uri didn't reduce per-query latency (Iter 326)

**Short answer:** `opa.policy.batched-uri` does NOT apply to row-filter expression evaluation. It only batches schema visibility decisions (which tables, schemas, columns can you see). Row filters are a separate, per-query HTTP call that cannot be batched. Your latency hasn't improved because Trino is calling the row-filter endpoint, not the batched endpoint.

---

## What `batched-uri` Actually Batches

`opa.policy.batched-uri` optimizes **filtering candidate resources within a single schema visibility decision**:
- `FilterTables` — "which tables in this schema can you see?"
- `FilterSchemas` — "which schemas in this catalog can you see?"
- `FilterColumns` — "which columns on this table can you see?"
- `FilterCatalogs` — "which catalogs can you see?"
- `FilterViews` — "which views can you see?"

**How batching works:** Suppose a user browses a schema with 50 tables.
- **Without `batched-uri`:** Trino makes 50 separate calls to `opa.policy.uri` (one per table) → 50 round-trips
- **With `batched-uri`:** Trino makes 1 call containing all 50 tables in `action.filterResources` → OPA returns the indices of visible tables → 1 round-trip

## What `batched-uri` Does NOT Apply To

Row filtering is a **completely separate authorization function** from schema visibility. When your query runs:

1. Trino calls `opa.policy.row-filters-uri` (a different endpoint entirely) — once per query at planning time
2. OPA returns a filter expression like `"tenant_id = 'acme'"`
3. Trino injects that expression as a WHERE predicate before execution
4. This is **one HTTP call per query** — not one per table or per candidate row

`batched-uri` has no effect on this flow because it targets filter-list operations only.

## The Fundamental Distinction

### Schema visibility: "Which resources can this user see?"
- Answered by `opa.policy.uri` (one call per candidate) or `opa.policy.batched-uri` (one call for N candidates)
- **Can be batched** because multiple candidates are evaluated together
- Example: `SHOW TABLES IN analytics` → one call with 50 candidates, OPA returns visible indices

### Row visibility: "Which rows can this user see?"
- Answered by `opa.policy.row-filters-uri` — returns one WHERE expression per query
- **Cannot be batched** — each query is independent; there are no N candidates to filter in parallel
- Example: `SELECT * FROM events` → one call, OPA returns `"tenant_id = 'acme'"` → Trino injects it

**Why batching doesn't apply to row filters:** There are no candidate resources to filter. A row filter is a single decision about one table in one query. You can't batch "compute the row filter for Query 1" and "compute the row filter for Query 2" — they're independent, each needing OPA's decision synchronously before the query can proceed.

## Why Row-Filter Latency Cannot Be Eliminated With Batching

Every row-filter decision incurs:
1. **One OPA HTTP call per query** — no batching mechanism exists, even in theory
2. **Synchronous evaluation** — Trino's query planner blocks until OPA responds
3. **No decision cache** — the Trino OPA plugin has no `opa.policy.cache-ttl-seconds` or equivalent; every query makes a fresh HTTP call, even if the same user queries the same table twice

## What Actually Reduces OPA Row-Filter Overhead

### 1. Deploy OPA as a sidecar (biggest impact)

Run OPA in the same Kubernetes pod as the Trino coordinator:
- Network latency drops from 10–20ms (cross-service) to <1ms (in-pod loopback)
- If your row-filter calls average 15ms and you're making one per query, this alone cuts ~14ms per query
- Recommended by the Trino OPA plugin docs as the production deployment pattern for latency-sensitive workloads

### 2. Tune Trino's HTTP client pool

The bottleneck may be on Trino's side if many queries run concurrently:

```properties
# etc/access-control.properties
opa.http-client.max-connections=64        # raise from default 32
opa.http-client.request-timeout=30s
```

With 32 available connections and 40 concurrent queries, Trino queues OPA calls. Increasing replicas alone doesn't fix pool exhaustion.

### 3. Reduce Rego policy complexity

Row-filter policies block every query. Common bottlenecks:
- Large data-bundle lookups (iterating a big tenant-permissions table on every call)
- Deep nested policy traversal
- Unindexed scans like `some i; input.resources[i].tenant_id == ...`

Profile your Rego with `opa eval --profile` to find slow rules.

### 4. Scale OPA horizontally

Add OPA replicas to spread load. Combine with the HTTP client pool tuning above.

## Diagnosing Where the Latency Is

Enable OPA HTTP debug logging in `etc/log.properties`:
```
io.trino.plugin.opa.OpaHttpClient=DEBUG
```

You'll see entries like:
```
OpaHttpClient - POST /v1/data/trino/rowFilters Status: 200 Response time: 42ms
OpaHttpClient - POST /v1/data/trino/rowFilters Status: 200 Response time: 38ms
```

If calls to `/v1/data/trino/allow` (not `rowFilters`) are numerous, those are single-resource schema-visibility checks — `batched-uri` would batch those. If all calls are to `rowFilters`, batched-uri can't help and you need sidecar + Rego optimization.

## The Complete Endpoint Map

| Property | Operation | Batchable? |
|---|---|---|
| `opa.policy.uri` | Single-resource allow/deny (CreateTable, DropTable, ExecuteQuery) + fallback for filter-list if `batched-uri` not set | No |
| `opa.policy.batched-uri` | FilterTables, FilterSchemas, FilterColumns, FilterCatalogs, FilterViews | Yes — within one filter operation |
| `opa.policy.row-filters-uri` | Row-filter expression evaluation ("which rows can they see?") | **No — per-query call, always** |
| `opa.policy.column-masking-uri` | Per-column masking decisions | No |
| `opa.policy.batch-column-masking-uri` | All columns of one table at once | Yes — per table |

## Recommended Configuration for Your Stack

```properties
# etc/access-control.properties
access-control.name=opa
opa.policy.uri=http://localhost:8181/v1/data/trino/allow
opa.policy.batched-uri=http://localhost:8181/v1/data/trino/batchAllow
opa.policy.row-filters-uri=http://localhost:8181/v1/data/trino/rowFilters
opa.policy.batch-column-masking-uri=http://localhost:8181/v1/data/trino/batchColumnMask
opa.http-client.max-connections=64
opa.http-client.request-timeout=30s
opa.log-requests=false
```

Using `localhost` assumes OPA is deployed as a sidecar. If OPA is a separate service, replace with the service DNS name — but plan for 10–20ms additional latency per query from network overhead.

## Summary

You configured `batched-uri` correctly, but it's solving a different problem:

| Problem | Solution |
|---|---|
| Too many calls when browsing catalog/schemas | `opa.policy.batched-uri` ✓ |
| Slow per-query row-filter evaluation | Sidecar deployment + Rego optimization + HTTP pool tuning |
| Per-query latency from network round-trip | Deploy OPA as sidecar in coordinator pod |
| OPA CPU saturation at high QPS | Add OPA replicas |

Row-filter latency cannot be eliminated — one HTTP call per query is the architecture. It can only be minimized by reducing per-call cost (sidecar = <1ms) and per-call work (simpler Rego).
