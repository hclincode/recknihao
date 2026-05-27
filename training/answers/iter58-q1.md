# Iter58 Q1 — Answer

**Question**: We're going through our first SOC2 Type II audit and the auditors are asking for logs showing which customer queried which data, and when. Right now we have nothing — Trino runs queries and there is no record kept anywhere. The security reviewer specifically wants to be able to answer "did any customer access data that isn't theirs?" and "show me every query tenant X ran in the past 90 days." How do we set up that kind of logging on Trino? We are on-prem Kubernetes so there's no cloud-console button to press. Where do the logs even go once we have them?

---

## Answer

You need Trino's built-in HTTP event listener — it ships with no third-party plugins required. For every query Trino executes, it POSTs a structured JSON event to an audit collector you specify. That JSON contains the tenant identity, exact SQL text, tables touched, and query timing — exactly what the auditor needs.

### Step 1: Enable the HTTP event listener on the coordinator

On your Trino coordinator pod, create `etc/http-event-listener.properties`:

```properties
event-listener.name=http
http-event-listener.connect-ingest-uri=http://audit-collector:8080/events
http-event-listener.log-completed=true
http-event-listener.log-created=false
```

Then add a reference in `etc/config.properties`:

```properties
event-listener.config-files=etc/http-event-listener.properties
```

For Kubernetes: mount both files via a ConfigMap in the Trino coordinator pod spec. After deploying, **restart the coordinator pod** — the event listener is not hot-reloaded. You need a clean restart for it to take effect.

### Step 2: What data the event listener captures

For every completed query, Trino POSTs nested JSON to your configured URI. The JSON is nested — you must use the correct paths:

| What you need | JSON path | What it tells you |
|---|---|---|
| Which tenant ran the query | `context.user` | Maps directly to the tenant's service account |
| The exact SQL | `metadata.query` | Full query text verbatim |
| Tables and columns touched | `ioMetadata.inputs[n].tableName` and `.columns[]` | Array of tables read |
| Query ID and timing | `metadata.queryId`, `createTime`, `endTime` | For reconstructing timeline |
| Success or failure | `metadata.queryState` | `FINISHED` or `FAILED` (both are logged) |

A concrete example of what a query event looks like:

```json
{
  "context": {
    "user": "acme-service-account",
    "principal": "acme-service-account"
  },
  "metadata": {
    "queryId": "20260524_091234_00001_xyz",
    "query": "SELECT COUNT(*) FROM tenant_acme.events WHERE occurred_at >= DATE '2026-05-01'",
    "queryState": "FINISHED"
  },
  "ioMetadata": {
    "inputs": [
      {
        "catalogName": "iceberg",
        "schemaName": "analytics",
        "tableName": "events",
        "columns": ["event_id", "tenant_id", "occurred_at"]
      }
    ]
  }
}
```

**Important**: the JSON is nested, not flat. Parsing with top-level keys like `user` or `query` returns null. Always use the full paths above.

### Step 3: Where logs go (three on-prem options)

**Option 1: Loki sidecar** — run a Loki HTTP endpoint as a cluster service. Trino POSTs directly to it. Loki stores as structured logs, queryable via Grafana's LogQL. No new infrastructure if Loki is already deployed.

**Option 2: Filebeat / ELK stack** — run Filebeat as a DaemonSet pointing at Filebeat's HTTP intake. Events ship to Elasticsearch. Good if you already use ELK for application logs.

**Option 3: Iceberg audit table in MinIO** — the most practical for pure on-prem. Build a lightweight HTTP receiver (FastAPI or Go) that batches events and writes to an Iceberg table:

```sql
CREATE TABLE iceberg.analytics.query_audit_log (
    query_id      VARCHAR,
    trino_user    VARCHAR,
    query_text    VARCHAR,
    create_time   TIMESTAMP,
    query_state   VARCHAR,
    queried_tables VARCHAR   -- JSON array of catalog.schema.table
) USING iceberg
PARTITIONED BY (day(create_time));
```

Advantage: your security team runs SQL directly via Trino to answer auditor questions — no separate log system to manage.

### Step 4: Answer the auditor's two questions

**"Did any customer access data that isn't theirs?"**

Match `context.user` against `ioMetadata.inputs.tableName`. If a tenant's service account queried the base table directly (not their scoped view), that's a cross-tenant access signal:

```sql
SELECT
    query_id,
    trino_user,
    query_text,
    create_time
FROM iceberg.analytics.query_audit_log
WHERE query_text LIKE '%FROM analytics.events%'
  AND trino_user LIKE '%-service-account'
  AND query_state = 'FINISHED'
ORDER BY create_time DESC;
```

If this returns rows where a tenant's service account is querying the base table `analytics.events` (rather than their scoped view), that's either a misconfigured role or a breach attempt.

**"Show me every query tenant X ran in the past 90 days"**

```sql
SELECT
    query_id,
    query_text,
    create_time,
    query_state
FROM iceberg.analytics.query_audit_log
WHERE trino_user = 'acme-service-account'
  AND create_time >= NOW() - INTERVAL '90' DAY
ORDER BY create_time DESC;
```

### Why no extra tagging is needed

Because your multi-tenant setup uses role-per-tenant (each customer has their own Trino service account), the `context.user` field in every event already maps to the tenant automatically. Acme's service account authenticates to Trino with a JWT, and that JWT's `sub` claim becomes `context.user` in the event payload. No lookup table or extra tagging is needed — the audit event already knows which tenant ran the query.

### Catching misconfigured roles via `ioMetadata.inputs`

If a tenant's role was accidentally granted SELECT on the base table instead of only their view, the audit log catches it: a query from `acme-service-account` that lists `analytics.events` (not `tenant_acme.events`) in `ioMetadata.inputs` is a red flag. The `ioMetadata.inputs` array is the smoking gun for access-control drift.

### Deployment checklist

1. Create `etc/http-event-listener.properties` with your audit collector URI
2. Reference it in `etc/config.properties`
3. Restart the Trino coordinator pod
4. Deploy your audit collector
5. Verify events are flowing: check a few query events in your log store
6. Test the two auditor queries above
7. Document in your SOC2 runbook: "Query audit trail is maintained in [Loki / ELK / Iceberg table]. Cross-tenant access is detected by monitoring `context.user` vs `ioMetadata.inputs.tableName`."
