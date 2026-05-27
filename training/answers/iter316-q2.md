# Answer to Q2: OPA Decision Log Debugging for Trino Access Control (Iter 316)

OPA decision logs are powerful but arrive as massive, unstructured JSON. Here's what's actually in them, how to read them, and how to set up so debugging doesn't take an hour.

## What's in an OPA decision log entry

Each entry records one authorization decision. A single decision-log line contains:

**The input Trino sent OPA:**
- The exact operation (`SelectFromColumns`, `FilterTables`, `ExecuteQuery`, etc.) — what the user tried to do
- The resource being accessed (catalog, schema, table, column names) — what they tried to touch
- The calling principal's username and groups — who made the request
- The query ID (for cross-referencing with Trino's event logs)

**The output OPA returned:**
- Whether the decision was `allow: true` or `allow: false`
- Which Rego rules evaluated and what values they produced
- Policy evaluation latency at `metrics.timer_rego_query_eval_ns` (exact key — `eval_ns` alone won't match)

**Critical caveat:** OPA decision logs are **not durable by default.** OPA writes to stdout; without a log shipper (Fluent Bit, Vector, etc.) feeding into OpenSearch, Loki, or similar, logs vanish on pod restart. You must have that shipping pipeline in place before reliable debugging is possible.

## How to read a log to answer "why was this user allowed/denied?"

**Step 1: Find the entry by query ID and principal.**

Grab the query ID from the error message or from `system.runtime.queries`. Search your log store:
- `input.context.queryId` = that query ID
- `input.context.identity.user` = the principal name

**Step 2: Check which operation was denied.**

Look at `input.action.operation`. Common ones:
- `SelectFromColumns` — user tried to SELECT specific columns
- `FilterTables` — planner asked OPA "which of these tables can this user see?"
- `FilterCatalogs` / `FilterSchemas` — catalog/schema visibility filtering
- `ExecuteQuery` — query started execution

If `FilterTables` is denied, look at `input.action.filterResources` — that's the full list of table candidates Trino sent OPA. You'll see exactly which were allowed and which were filtered out.

**Step 3: Cross-check identity and resource.**

Verify:
- Is `input.context.identity.user` the principal you expected?
- Is `input.action.resource.table.tableName` the table they're trying to access?
- Are the groups in `input.context.identity.groups` correct?

**Step 4: Use the decision ID.**

The `decision_id` is a unique ID per decision. Grep OPA's logs for it to see the full Rego rule trace — exactly which rules fired and what they returned.

## The smarter setup

### 1. Ship logs to a queryable store (non-negotiable)

Your OPA configuration:
```yaml
decision_logs:
  console: true
services:
  backend:
    url: https://opa-decisions.observability.svc.cluster.local/ingest
```

Use Vector, Fluentd, or Fluent Bit to ship OPA stdout → OpenSearch (Kibana queries) or Loki (Grafana queries). This single step converts a 1-hour grep session into a 30-second dashboard query.

### 2. Use exact JSON paths in your queries

When building dashboards or alerts:
- `input.action.operation` — what operation
- `input.context.identity.user` — which principal
- `input.context.queryId` — join key to Trino event log
- `result.allow` — true or false
- `metrics.timer_rego_query_eval_ns` — evaluation latency

**Example OpenSearch DSL — all denials for a user in the last 24 hours:**
```
input.context.identity.user: "acme-svc" AND result.allow: false AND @timestamp: [now-24h TO now]
```

### 3. Enable batched-uri to reduce noise

When `opa.policy.batched-uri` is configured, a filter operation on 50 tables produces **one** decision-log line instead of 50 separate lines. The batch line shows all 50 candidates and which were returned — without the noise of 50 individual denies.

### 4. Build focused on-call dashboards

**Highest value first — "Deny events on sensitive catalogs":**
```
result.allow: false AND input.action.resource.table.catalogName: "analytics"
```

Any deny is either a misconfiguration (legitimate user blocked) or a potential security incident. Alert on these within the hour. This catches 90% of real issues.

**Second — policy evaluation latency:** Track `metrics.timer_rego_query_eval_ns`, alert if p95 climbs above ~50ms. A slow policy blocks query planning for everyone.

### 5. Three-way forensic cross-reference

For "why did my query return wrong data?", combine three sources:
1. **Trino event listener** — full query text, principal, wall-clock time, bytes scanned
2. **OPA decision log** — analysis-phase authorization decisions (join by `queryId`)
3. **Postgres `pg_stat_activity`** (if federated) — exact SQL Trino sent downstream

Together these answer "did OPA hide data?" vs. "did Postgres receive the wrong predicate?"

## One important behavior to know

OPA is consulted only at **query analysis time, not during execution.** A query that passed authorization and started executing will run to completion even if OPA crashes one second later. New queries will be rejected with `Access Denied` until OPA recovers, but in-flight queries are unaffected.

## Bottom line

Set up log shipping now — it's the prerequisite for everything else. Once logs are in OpenSearch/Loki, a 1-hour debugging session becomes a 5-minute dashboard query. For "why was user X denied access to table Y at time Z?", search by user + queryId + time range. The decision log tells you the exact answer: which operation fired, what input OPA evaluated, and whether it returned allow or deny.
