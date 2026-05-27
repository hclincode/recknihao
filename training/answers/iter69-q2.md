# Iter69 Q2 — Answer

**Question**: We have around 30 tenants today and I want to start tracking query performance per tenant — like, I want to know if a particular tenant's queries are consistently slow, or if one tenant is suddenly querying way more data than usual. Right now the only thing I have is general cluster metrics and slow query logs that don't break things down by tenant. How do other teams handle per-tenant query monitoring in a shared analytics setup? What do I actually look at to tell if one tenant is getting a worse experience than others, or if a tenant's data volume is quietly exploding and starting to affect the whole system?

---

## Answer

You already have the signals you need — they're built into Trino and Iceberg. The setup is about wiring them together into something queryable. Here's a three-layer approach that goes from live triage to historical trends.

### Layer 1: Live signal — `system.runtime.queries`

For right-now visibility (is any tenant being throttled or queuing right now?), query Trino's built-in `system.runtime.queries`. This table holds in-memory records of currently running and recently completed queries, with the tenant identity available through the `user` column (the JWT principal your tenants authenticate with).

```sql
-- Which tenants have running vs queued queries right now?
SELECT
  user                                                    AS tenant,
  resource_group_id,
  COUNT(*) FILTER (WHERE state = 'RUNNING')              AS running,
  COUNT(*) FILTER (WHERE state = 'QUEUED')               AS queued,
  MAX(elapsed_time)                                      AS longest_ms
FROM system.runtime.queries
WHERE state IN ('RUNNING', 'QUEUED')
GROUP BY user, resource_group_id
ORDER BY queued DESC, longest_ms DESC;
```

**What to look for:**
- `queued > 0` for a tenant: their resource group's `hardConcurrencyLimit` is full. Their new queries are waiting behind existing ones. Either their workload spiked or their limit is too tight.
- `longest_ms` consistently high for one tenant while others finish in milliseconds: their queries are reading more data or filtering less efficiently than others.
- One tenant's `running` count always equals the resource group cap while other tenants' queries sit in `QUEUED`: classic noisy-neighbor — one tenant is consuming all available slots in a shared group.

The `resource_group_id` column also tells you whether tenants are landing in the right group (a tenant in `global` instead of `global.tenant_acme` means the selector didn't match their JWT principal).

**Limitation**: `system.runtime.queries` is in-memory only. It holds the last N queries (typically 100–1000 before they age out). It's for live troubleshooting, not historical trend analysis.

### Layer 2: Historical audit — HTTP event listener + Iceberg audit table

For "which tenants have been slow over the past 30 days?" and "is tenant X's data volume growing?", you need persistent history. Trino ships a built-in HTTP event listener (no external plugins) that POSTs a structured JSON event to any HTTP endpoint for every completed query.

**Enable it on the coordinator.** Create `etc/http-event-listener.properties`:

```properties
event-listener.name=http
http-event-listener.connect-ingest-uri=http://audit-collector.internal:8080/events
http-event-listener.log-completed=true
http-event-listener.log-created=false
```

Reference it in `etc/config.properties` and restart the coordinator.

Each `QueryCompletedEvent` contains:
- `context.user` — the tenant's JWT principal
- `statistics.elapsedTimeMs` — wall time
- `statistics.totalBytes` — bytes read from MinIO (your I/O cost signal)
- `metadata.queryState` — `FINISHED`, `FAILED`, `QUEUED_TIMEOUT`
- `ioMetadata.inputs[n].tableName` — tables queried (tells you which tenant accessed which table)

Write these events to an Iceberg audit table (your existing MinIO + Hive Metastore stack handles this cleanly):

```sql
CREATE TABLE iceberg.analytics.query_audit (
  query_id     VARCHAR,
  tenant_id    VARCHAR,
  wall_time_ms BIGINT,
  bytes_read   BIGINT,
  query_state  VARCHAR,
  query_date   DATE
)
WITH (
  format = 'PARQUET',
  partitioning = ARRAY['day(query_date)']
);
```

Now you can ask the questions you actually care about:

```sql
-- P50 and P99 latency per tenant, last 7 days
SELECT
  tenant_id,
  COUNT(*)                                                          AS query_count,
  APPROX_PERCENTILE(wall_time_ms, 0.50)                           AS p50_ms,
  APPROX_PERCENTILE(wall_time_ms, 0.99)                           AS p99_ms,
  MAX(wall_time_ms)                                               AS max_ms
FROM iceberg.analytics.query_audit
WHERE query_date >= CURRENT_DATE - INTERVAL '7' DAY
  AND query_state = 'FINISHED'
GROUP BY tenant_id
ORDER BY p99_ms DESC;
```

A tenant with P99 at 60,000 ms while others are at 2,000 ms is either reading far more data or running queries without effective partition filters.

```sql
-- Data volume (bytes_read) per tenant, week over week
SELECT
  tenant_id,
  SUM(bytes_read) FILTER (WHERE query_date >= CURRENT_DATE - INTERVAL '7' DAY)  AS bytes_this_week,
  SUM(bytes_read) FILTER (WHERE query_date BETWEEN CURRENT_DATE - INTERVAL '14' DAY
                                               AND CURRENT_DATE - INTERVAL '8' DAY) AS bytes_last_week
FROM iceberg.analytics.query_audit
WHERE query_date >= CURRENT_DATE - INTERVAL '14' DAY
  AND query_state = 'FINISHED'
GROUP BY tenant_id
ORDER BY bytes_this_week DESC;
```

A tenant whose `bytes_this_week` is 10× `bytes_last_week` deserves a call — their app may be scanning full tables instead of filtering, or they onboarded a large data migration.

```sql
-- Queue saturation: tenants whose queries frequently timeout in queue
SELECT
  tenant_id,
  COUNT(*) FILTER (WHERE query_state = 'QUEUED_TIMEOUT') AS timeouts,
  COUNT(*)                                               AS total_queries,
  ROUND(100.0 * COUNT(*) FILTER (WHERE query_state = 'QUEUED_TIMEOUT')
        / COUNT(*), 1)                                  AS timeout_pct
FROM iceberg.analytics.query_audit
WHERE query_date >= CURRENT_DATE - INTERVAL '7' DAY
GROUP BY tenant_id
HAVING COUNT(*) FILTER (WHERE query_state = 'QUEUED_TIMEOUT') > 0
ORDER BY timeout_pct DESC;
```

A tenant at 5% queue timeouts needs a larger resource group. A tenant at 0% is well within their cap.

### Layer 3: Data volume growth — Iceberg metadata tables

Sometimes queries slow down not because they're inefficient but because the tenant's raw data volume is growing. Iceberg's `$partitions` metadata table lets you track this at the source:

```sql
-- Current data size per tenant in today's partition
SELECT
  partition.tenant_id,
  COUNT(*)              AS partition_files,
  SUM(record_count)     AS total_rows,
  SUM(total_size) / 1e9 AS size_gb
FROM iceberg.analytics."events$partitions"
WHERE partition.event_date = CURRENT_DATE
GROUP BY partition.tenant_id
ORDER BY size_gb DESC;
```

Run this weekly and compare. A tenant jumping from 50 GB to 500 GB between weeks means:
- They onboarded a large customer (expected, you should know about it)
- They ran a historical backfill (check with them)
- There's a data pipeline bug producing duplicates (investigate)

This is your earliest warning system for data growth before it starts affecting query performance.

### Three-tier operational workflow

| Signal | Tool | Use case |
|---|---|---|
| Right now | `system.runtime.queries` | Is any tenant being throttled right now? Live incident triage |
| Last 7–30 days | HTTP event listener → audit table | Which tenants are consistently slow? Which are queuing? |
| Source volume | Iceberg `$partitions` metadata | Is a tenant's raw data growing unexpectedly? |

**Important security note**: Your tenants must not have SELECT access to `system.runtime.queries` — they would see every other tenant's query text and timing. The OPA policy on your production stack must deny the `system` catalog to tenant principals. Your monitoring dashboards should query `system.runtime.queries` as an admin service account, not expose it to tenants.

### Where to start

If you want this running by end of week:
1. Enable the HTTP event listener on the Trino coordinator (one config file + restart).
2. Write a small receiver service (10 lines of FastAPI or Express) that batches events to the Iceberg audit table.
3. Set up a Grafana dashboard (or a Trino-based BI dashboard) running the latency and bytes-read queries above.
4. Add a weekly query against `$partitions` to your data team's runbook.

You'll have per-tenant P50/P99 latency, bytes-read growth curves, and queue saturation visibility within a few hours of setup.
