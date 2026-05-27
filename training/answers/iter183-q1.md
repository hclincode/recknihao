# Iter 183 Q1 — OPA + Trino Event Listener for Federation Query Audit Trail

## Answer

Your security team is asking the right question. **OPA logs alone are insufficient for a complete audit trail because they capture authorization decisions, not execution details.**

---

### Why OPA logs alone fall short

OPA is configured to log every policy evaluation — whether a query is allowed or denied. But OPA's decision logs show only:
- **Who tried** (user identity from JWT claims)
- **What resource** (catalog, schema, table)
- **Allow or deny** (the authorization decision)

OPA does NOT capture:
- The actual SQL text that ran
- How many rows were returned
- Wall-clock time, CPU time, or bytes scanned
- Error messages if the query failed at runtime

**Critical caveat on durability**: OPA's decision logs default to `console: true` (stdout only). Without external log shipping to a durable backend (OpenSearch, Loki), these logs evaporate when the OPA pod restarts, and `kubectl logs` only retains the most recent MB. For "show me what happened last week," stdout is not durable.

---

### The Trino event listener captures what OPA misses

Trino exposes an **event listener** plugin that fires when a query completes. The HTTP event listener (recommended for on-prem Kubernetes) ships structured `QueryCompletedEvent` records containing:

- **Full SQL text** — the exact query that ran
- **User identity** — the authenticated user (from JWT, passed through to Trino)
- **Execution metrics**:
  - `executionTime` — wall-clock milliseconds
  - `cpuTime` — CPU milliseconds
  - `peakMemoryBytes` — max memory during query
  - `outputBytes` / `outputRows` — bytes and rows returned to the client
  - `physicalInputBytes` / `physicalInputRows` — bytes and rows read from storage before filtering
- **Catalog / schema** — parsed from the query statement
- **Error info** — error code and message if the query failed
- **Query ID** — correlatable with OPA decision logs
- **Start and end timestamps** — precise execution window

---

### The complementary roles

| Aspect | OPA decision log | Trino event listener |
|---|---|---|
| **What it captures** | Authorization decision (allow/deny) + policy rules | Query execution (SQL, runtime, bytes, errors) |
| **Durability** | NOT durable by default (stdout only) | Durable if shipped to OpenSearch/Loki |
| **Identity captured** | Trino principal + JWT groups | Same (Trino extracts JWT identity for event) |
| **Row count** | No | Yes — `outputRows` and `physicalInputRows` |
| **Bytes scanned** | No | Yes — `physicalInputBytes` and `outputBytes` |
| **Full SQL** | No | Yes |

For "engineer X ran SELECT * on billing at 3 AM and how many rows came back," **you need the event listener**. OPA tells you "engineer X was allowed"; the event listener tells you "engineer X ran the query and got back 50,000 rows in 12 seconds."

---

### How to wire the HTTP event listener

**Step 1: Create `etc/event-listener.properties` on the Trino coordinator**

```properties
event-listener.name=http
http-event-listener.connect-ingest-uri=http://vector-svc.observability.svc.cluster.local:8686/
http-event-listener.log-completed=true
http-event-listener.log-created=false
```

**Critical**: This goes in a **dedicated `etc/event-listener.properties` file, NOT in `etc/config.properties`.** Putting event-listener config in `config.properties` is silently ignored — the same trap as resource group properties (which go in `etc/resource-groups.properties`, not `config.properties`).

**Step 2: Register the event-listener config file in `etc/config.properties`**

```properties
event-listener.config-files=etc/event-listener.properties
```

**Step 3: Mount in Kubernetes ConfigMap and restart coordinator**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: trino-config
  namespace: trino
data:
  config.properties: |
    coordinator=true
    node.environment=production
    event-listener.config-files=etc/event-listener.properties
    # ... other coordinator settings ...
    
  event-listener.properties: |
    event-listener.name=http
    http-event-listener.connect-ingest-uri=http://vector-svc.observability.svc.cluster.local:8686/
    http-event-listener.log-completed=true
    http-event-listener.log-created=false
```

---

### What QueryCompletedEvent looks like

```json
{
  "queryId": "20260526_030000_12345_abcde",
  "query": "SELECT id, email, amount FROM billing_pg.public.transactions WHERE created_at > TIMESTAMP '2026-05-26 00:00:00'",
  "statementType": "SELECT",
  "user": "engineer@example.com",
  "catalog": "billing_pg",
  "schema": "public",
  "createTime": "2026-05-26T03:00:00.123Z",
  "endTime": "2026-05-26T03:00:12.456Z",
  "executionTime": 12333,
  "physicalInputBytes": 524288000,
  "physicalInputRows": 1000000,
  "outputBytes": 2097152,
  "outputRows": 50000,
  "errorCode": null,
  "success": true
}
```

The `outputRows` and `physicalInputRows` fields answer "how many rows came back?" The timestamps pin exactly when the query ran.

---

### Do row counts work for federation queries?

**Yes.** Even though Postgres doesn't natively report "row count returned" to Trino's coordinator, Trino counts the rows it fetches via JDBC. The `outputRows` field is the count the client received; `physicalInputRows` is what Postgres scanned (before any Trino-side filtering). For a federated `SELECT * FROM billing_pg.public.transactions`, both values are reported accurately in the event.

---

### How to filter the event stream for billing_pg / app_pg

Once events land in OpenSearch or Loki:

```json
// OpenSearch:
{ "catalog": "billing_pg", "user": "engineer@example.com", "endTime": { "$gt": "2026-05-26T03:00:00Z" } }
```

```logql
// Loki:
{job="trino-events"} | json | catalog="billing_pg" | user="engineer@example.com"
```

Filter by:
- `catalog IN ("billing_pg", "app_pg")` — isolate federation catalog events
- `user = "engineer@example.com"` — specific user
- `endTime` range — the 3 AM window
- `success = false` — failed queries only

---

### Making OPA decision logs durable

OPA's `console: true` setting writes to stdout only. To make them durable:

```yaml
# In OPA config.yaml:
decision_logs:
  console: true      # local stdout for live tailing
  service: backend   # also push to remote sink
services:
  backend:
    url: https://opa-decisions.observability.svc.cluster.local/ingest
```

Route the `backend` service to your OpenSearch/Loki cluster. Without this, OPA logs are ephemeral.

---

### Recommended production setup

1. **Enable and ship OPA decision logs** to OpenSearch/Loki (durable "who tried to access what, with allow/deny").
2. **Enable the HTTP event listener** → Vector → OpenSearch/Loki (durable "what actually ran, how long, how many rows").
3. **Build dashboards**:
   - OPA: "Deny events on billing_pg" (alert on unauthorized access attempts)
   - Event listener: "Federation queries by catalog/user, filtered by time range"
4. **Correlate the two**: event listener includes `queryId`; OPA logs include correlation headers — join on `queryId` to see authorization decision + execution details in one view.

For your specific question ("did engineer X run SELECT * on billing at 3 AM, how many rows?"):
```
event-listener query: catalog="billing_pg" AND user="engineer@example" AND endTime > "2026-05-26T03:00:00Z"
→ read outputRows from the matching event
```
