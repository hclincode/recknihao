# Iter93 Q1 — Answer

**Question**: Which of our 80 tenants are the heaviest users of our analytics system? Is there a way to get per-tenant breakdowns of query volume and data scanned?

---

## Answer

Yes — Trino exposes exactly what you need. Here are two complementary approaches: one for immediate visibility, one for durable historical reporting.

## Quick win: system.runtime.queries for live insights

Run this as your admin/data-team service account (not as any tenant principal):

```sql
-- Top tenants by data scanned (most recent queries in memory)
SELECT
  "user",
  COUNT(*) AS query_count,
  ROUND(SUM(CAST(JSON_EXTRACT_SCALAR(statistics, '$.totalBytes') AS BIGINT)) / 1024 / 1024 / 1024, 1) AS total_gb_scanned,
  ROUND(AVG(CAST(JSON_EXTRACT_SCALAR(statistics, '$.elapsedTime') AS BIGINT)) / 1000, 1) AS avg_seconds_per_query
FROM system.runtime.queries
WHERE query_type = 'SELECT'
  AND state IN ('FINISHED', 'FAILED')
GROUP BY "user"
ORDER BY total_gb_scanned DESC
LIMIT 10;
```

**Caveat:** `system.runtime.queries` lives only in coordinator memory — history is gone after a coordinator restart. Good for "who's heavy right now" but not for monthly billing.

## Durable billing-grade tracking: HTTP event listener + Iceberg audit log

For tiered pricing, you need persistent historical data. Trino's **HTTP event listener** emits structured JSON for every completed query and POSTs it to a collector you run.

**Step 1: Enable the HTTP event listener on the Trino coordinator**

Create `/etc/http-event-listener.properties`:
```properties
event-listener.name=http
http-event-listener.connect-ingest-uri=http://audit-collector:8080/events
http-event-listener.log-completed=true
http-event-listener.log-created=false
```

Reference it in `/etc/config.properties`:
```properties
event-listener.config-files=etc/http-event-listener.properties
```

Restart the Trino coordinator (not hot-reloaded).

**Step 2: Create an Iceberg audit log table**

```sql
CREATE TABLE iceberg.analytics.query_audit_log (
  query_id          VARCHAR,
  user              VARCHAR,       -- tenant service account principal
  state             VARCHAR,       -- 'FINISHED', 'FAILED'
  error_code        VARCHAR,
  created_time      TIMESTAMP,
  completed_time    TIMESTAMP,
  elapsed_ms        BIGINT,
  cpu_ms            BIGINT,
  bytes_scanned     BIGINT,        -- compressed bytes read from MinIO
  peak_memory_bytes BIGINT,
  create_time       DATE
)
WITH (
  location = 's3a://lakehouse/analytics/query_audit_log/',
  format = 'PARQUET',
  partitioning = ARRAY['day(create_time)']
);
```

The HTTP event listener payload includes:
- `context.user` → which tenant's service account
- `statistics.totalBytes` → data scanned (the real cost metric)
- `statistics.elapsedTime` and `statistics.cpuTime` → execution time
- `metadata.queryState` → FINISHED or FAILED

**Step 3: Weekly per-tenant usage report**

```sql
SELECT
  user,
  DATE_TRUNC('week', completed_time) AS week,
  COUNT(*) AS total_queries,
  COUNT(*) FILTER (WHERE state = 'FINISHED') AS successful_queries,
  COUNT(*) FILTER (WHERE state = 'FAILED') AS failed_queries,
  ROUND(SUM(bytes_scanned) / 1024 / 1024 / 1024, 1) AS total_gb_scanned,
  ROUND(SUM(cpu_ms) / 1000.0, 0) AS total_cpu_seconds,
  ROUND(AVG(elapsed_ms) / 1000.0, 2) AS avg_query_time_seconds
FROM iceberg.analytics.query_audit_log
WHERE completed_time >= CURRENT_DATE - INTERVAL '7' DAY
GROUP BY user, DATE_TRUNC('week', completed_time)
ORDER BY total_gb_scanned DESC;
```

## Storage footprint: instant per-tenant breakdown (no audit log needed)

Before you have a week of query history, use Iceberg metadata tables to see storage footprint right now:

```sql
SELECT
  partition.tenant_id,
  COUNT(*) AS file_count,
  ROUND(SUM(file_size_in_bytes) / 1024 / 1024 / 1024, 1) AS total_gb
FROM iceberg.analytics."events$files"
GROUP BY 1
ORDER BY 3 DESC
LIMIT 20;
```

This answers "which tenants have the most data" instantly. Pair it with query volume from the audit log for a complete picture.

## Critical security note

Only your internal billing/data team should have access to `system.runtime.queries` or `query_audit_log`. Your OPA policy must deny tenant service accounts access to the `system` catalog and all `$`-suffix metadata tables. If a tenant can read `system.runtime.queries`, they can see every other tenant's SQL — including customer IDs in WHERE clauses. That's a P0 data leak.
