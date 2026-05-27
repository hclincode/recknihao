# Iter 192 Q1 — OPA Authorization Audit Trail for Trino

## Answer

## Where OPA Logs Authorization Decisions

OPA logs every authorization decision to **two possible places** — you must configure and ship at least one for durability:

**1. Console output (ephemeral by default)**
Enable in OPA's config:
```yaml
decision_logs:
  console: true
```
This writes one JSON record per policy evaluation to OPA's stdout. Without shipping to an external store, these logs live only in the OPA container's stdout buffer and disappear on pod restart or Kubernetes log rotation.

**2. Remote HTTP sink (production-grade)**
For durability, configure OPA to push decisions to a collector:
```yaml
decision_logs:
  service: backend
services:
  backend:
    url: https://opa-decisions.observability.svc.cluster.local/ingest
```
Then ship those decisions to OpenSearch, Loki, or your SIEM using Vector, Fluentd, or Filebeat.

## What's in Each Decision Log Entry

When OPA evaluates an authorization request, it emits a structured JSON entry containing:

- **`input.action.operation`** — the operation name (e.g., `"CreateCatalog"`, `"DropCatalog"`, `"SelectFromColumns"`)
- **`input.action.resource`** — what the user tried to access (catalog name for DDL, or catalog/schema/table/column for queries)
- **`input.context.identity.user`** — the Trino principal who made the request
- **`input.context.identity.groups`** — the user's group memberships (from JWT claim extraction)
- **`result.allow`** — `true` or `false` (the authorization decision)
- **`metrics.eval_ns`** — nanoseconds to evaluate the policy
- **`decision_id`** — a trace ID you can correlate with Trino's query ID

**Example — non-admin attempts CREATE CATALOG:**
```json
{
  "input": {
    "context": {
      "identity": { "user": "engineer-bob", "groups": ["engineers"] },
      "queryId": "20260526_120000_00001_xxxxx"
    },
    "action": {
      "operation": "CreateCatalog",
      "resource": { "catalog": { "name": "test" } }
    }
  },
  "result": { "allow": false },
  "metrics": { "eval_ns": 1250000 }
}
```

## Distinguishing CREATE CATALOG from Query Access

**Yes, the log entries are structured enough to tell them apart.** The `operation` field is the key:

| Operation | Meaning |
|---|---|
| `"CreateCatalog"` | DDL: someone tried to create a catalog |
| `"DropCatalog"` | DDL: someone tried to drop a catalog |
| `"SelectFromColumns"` | Query: read data from a table (resource shows catalog/schema/table/column) |
| `"FilterCatalogs"` | Query metadata: planner checked which catalogs the user can see |
| `"SelectFromTable"` | Query: read from an entire table |

A CREATE CATALOG denial is logged as `operation: "CreateCatalog"` with `allow: false`. A user querying the `app_pg` catalog is logged as `operation: "SelectFromColumns"` with resource details showing `catalog: "app_pg"` etc.

## Production Audit Logging Configuration

**Step 1: Enable decision logging in OPA**
```yaml
decision_logs:
  console: true  # for visibility during testing
  service: backend  # for production durability
services:
  backend:
    url: https://vector.observability.svc.cluster.local:8686/opalogs
```

**Step 2: Ship the stream to a durable backend**
Deploy Vector, Fluentd, or Filebeat to forward OPA stdout to OpenSearch/Loki:

```yaml
# Vector configuration example
sources:
  opa_logs:
    type: file
    include: ["/var/log/containers/*_opa_*.log"]
sinks:
  opensearch:
    type: opensearch
    inputs: [opa_logs]
    endpoints: ["https://opensearch.observability.svc.cluster.local:9200"]
```

**Step 3: Query from your SIEM / OpenSearch**
```json
// Denied CREATE CATALOG attempts in the last week
{
  "query": {
    "bool": {
      "must": [
        { "term": { "result.allow": false } },
        { "term": { "input.action.operation": "CreateCatalog" } },
        { "range": { "timestamp": { "gte": "now-7d" } } }
      ]
    }
  }
}
```

```json
// Users querying the app_pg catalog in the last 7 days
{
  "query": {
    "bool": {
      "must": [
        { "match": { "input.action.resource.catalog": "app_pg" } },
        { "term": { "result.allow": true } },
        { "range": { "timestamp": { "gte": "now-7d" } } }
      ]
    }
  }
}
```

## Important: OPA Decision Logging vs Trino Debug Logging

These are **separate and serve different purposes**:

- **Trino's OPA plugin debug logging** (`opa.log-requests=true`, `opa.log-responses=true` in `etc/access-control.properties` + `io.trino.plugin.opa.OpaHttpClient=DEBUG` in `etc/log.properties`) — **for development/debugging only**. Extremely verbose (one entry per Trino query for every SQL operation). Enabling it in production produces gigabytes of logs per day and slows query planning. Turn on, reproduce a problem, turn off.

- **OPA's decision logging** — designed for production durable audit. Structured JSON, queryable by timestamp/user/operation/allow-deny, ships efficiently to your observability platform. This is what you want for ongoing compliance.

## High-Value Audit Dashboards

Once OPA decision logs land in OpenSearch/Loki:

1. **Deny events on sensitive catalogs** — filter `result.allow = false AND input.resource.catalog IN ("app_pg", "billing_pg")`. Alert within the hour.
2. **CREATE CATALOG attempts by non-admins** — anyone outside `platform-admin` group attempting `CreateCatalog`. Should be empty if policy is working.
3. **Catalog access patterns by user over 7 days** — detect unusual access patterns.
4. **Policy evaluation latency** — track `metrics.eval_ns` over time; p95 >50ms means query planning slows for everyone.

## Durability Wiring Checklist

Before claiming "we have OPA audit logging":

- [ ] `decision_logs.console: true` enabled in OPA config
- [ ] Vector/Fluentd/Filebeat sidecar tailing OPA stdout and pushing to OpenSearch/Loki
- [ ] Retention policy set (30+ days minimum for compliance)
- [ ] Dashboard filters for deny events on sensitive catalogs with alerting enabled
- [ ] End-to-end test: run a test CREATE CATALOG, watch decision log appear in SIEM within seconds

**Without the shipping wiring, decision logs evaporate on pod restart and you have no audit trail at all.** OPA captures every decision; backend durability is your responsibility.
