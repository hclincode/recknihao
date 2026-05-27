# Answer to Q2: OPA Row-Filter Performance Under High Concurrency (Iter 318)

## How OPA is called — once per query at analysis time, not per row

OPA is called **once per query during the analysis (planning) phase** at the coordinator. This happens before the query executes — OPA returns a WHERE expression (e.g., `tenant_id = 'acme'`), Trino's planner injects it into the query plan, and then the query runs with no further OPA involvement. OPA is never called per row, per scan, or during execution. Rows are filtered by the injected predicate, not by OPA.

So with 50–80 concurrent users, Trino's coordinator is making ~50–80 OPA authorization calls per dashboard refresh cycle. That sounds manageable — but the problem is most likely that each query triggers **multiple OPA HTTP calls**, not one.

## Why you might be making many more calls than you think

Several Trino operations trigger separate OPA requests:

- **Query analysis:** 1 call for the row filter decision (your `rowFilters` rule)
- **Schema exploration (SHOW TABLES, SHOW SCHEMAS):** Without batched-uri, one call per candidate table or schema in the listing — 200-table schema = 200 OPA calls per `SHOW TABLES`
- **Column masking (if configured):** Without batch endpoint, one call per column referenced in the query — a 30-column table = 30 OPA calls per query

If your stack has any of these without batching enabled, 50 concurrent users each triggering 30 OPA calls = **1,500 OPA requests per second** just for authorization. That's where the 2-3x latency under load comes from.

## Diagnose first: count OPA calls per query

Enable debug logging on the Trino coordinator's `etc/log.properties`:

```
io.trino.plugin.opa.OpaHttpClient=DEBUG
```

Restart the coordinator (**required — `opa.policy.*` config and logging changes are only read at startup, not hot-reloaded**), run a few dashboard queries under load, and grep for `OpaHttpClient` in the coordinator logs. You'll see every individual OPA HTTP request and its latency. If you see 20+ calls per query at 20-50ms each, that's 400-1000ms of authorization overhead before the query even starts executing.

## The tuning levers, in order of impact

### 1. Enable batched-uri for filter operations (highest impact for your setup)

If you're not already using it, add this to `etc/access-control.properties`:

```properties
opa.policy.batched-uri=http://opa:8181/v1/data/trino/batchAccessControl
```

This bundles all the per-table/per-schema filter checks into a single OPA call. One call covers 200 tables in a schema listing instead of 200 calls. This alone typically reduces OPA call volume by 10-50x for dashboards that list tables.

Your Rego needs a corresponding batch rule. For row filters, you're already using `rowFilters` — that's one call per query. The batched-uri covers the `FilterTables`/`FilterSchemas` operations.

### 2. Enable batch column masking (if you use column masking)

If `column-masking-uri` is configured, switch to (or add) `batch-column-masking-uri`:

```properties
opa.policy.batch-column-masking-uri=http://opa:8181/v1/data/trino/batchColumnMask
```

Note: when both are set, `batch-column-masking-uri` takes precedence — the single-column URI is silently ignored. One call per table instead of one call per column.

### 3. Scale OPA horizontally

At 200 tenants with 50-80 concurrent users, a single OPA pod is often the bottleneck. OPA is stateless — add replicas and put a load balancer in front:

```yaml
# In your Kubernetes deployment
replicas: 3  # or more, depending on measured latency
```

Rule of thumb: start at 1 OPA pod per ~20 concurrent Trino query users. At 80 concurrent users, 4 OPA pods is a reasonable starting point.

### 4. Optimize the Rego policy itself

If individual OPA call latency is high (>20ms) even with low concurrency, the Rego itself may be expensive:

- Avoid iterating over all 200 tenants in a single rule — use indexed lookup instead
- Pre-compute expensive mappings into the OPA data bundle rather than computing them in Rego
- Use OPA's `--instrument` flag briefly to profile which rules are slow

Check `metrics.timer_rego_query_eval_ns` in the OPA decision logs (exact field name — not `eval_ns`). If p95 is above ~5ms per evaluation, the policy logic itself needs optimization.

## The row-filter call pattern at 200 tenants

For your specific setup (OPA row filters for tenant isolation), the call pattern is:

- **Per query:** 1 OPA call to `rowFilters` → returns `{"expression": "tenant_id = 'acme'"}`
- **Per SHOW TABLES:** N calls (one per table) without batched-uri, or 1 call with it
- **Per column masked:** M calls (one per column) without batch masking, or 1 call with it

The row filter call itself is inherently one-per-query and efficient. If latency is spiking, it's almost always the SHOW TABLES / schema listing calls or column masking calls that are the culprit, not the row filters.

**Next step:** Enable `OpaHttpClient=DEBUG`, run under load, and count calls per query. If it's more than 1-2 per query, implement the batched-uri and/or batch column masking. That's the fix for 90% of OPA latency issues at your scale.
