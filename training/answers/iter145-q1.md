# Iter145 Q1 — Answer

**Question**: "We have a compliance requirement that IT and legal might need to audit who ran what on our analytics system. Right now I have no idea what queries got run, who ran them, or how long they took. Does Trino have any built-in way to see query history, or do we need to build something custom? And separately, is there a way to find which queries are eating up the most compute so we know where to focus optimization?"

---

## What Trino Provides Built-In for Live Query Monitoring

Trino exposes two system tables for queries **actively running or recently completed**:

- **`system.runtime.queries`** — one row per query with SQL text, user, query state, and lifecycle timing (created, started, ended). Key columns: `query_id`, `state`, `user`, `source`, `query`, `resource_group_id`, `queued_time_ms`, `planning_time_ms`, `created`, `end`.

- **`system.runtime.tasks`** — per-task telemetry including CPU and bytes consumed by each stage on each worker. Key columns: `physical_input_bytes`, `split_cpu_time_ms`, `node_id`, `query_id`, `state`.

Both tables are **ephemeral and in-memory on the coordinator**. They do not survive coordinator restarts, and old entries expire after `query.max-history` (default 100 queries) and `query.min-expire-age` (default 15 minutes). **There is no built-in 6-month query history from these tables** — you need to configure persistence.

---

## How to Get Query History for Compliance Auditing

Trino ships with **built-in event listener plugins** that persist completed queries to durable storage. Each `QueryCompletedEvent` includes: query ID, user, full SQL text, start/end time, final state (FINISHED, FAILED, CANCELED), bytes scanned, rows produced, and error details.

**For HTTP endpoint (recommended — ships to your logging stack):**

Create `etc/event-listener.properties`:
```properties
event-listener.name=http
http.event-listener.connect-ingest-uri=http://your-audit-api:8080/trino-events
```

Add to `etc/config.properties`:
```properties
event-listener.config-files=/etc/trino/event-listener.properties
```

Each completed query is POSTed as JSON to your endpoint. Route it to Fluent Bit, Vector, or a custom API that writes to a durable store.

**For Kafka (if you already run it):**

```properties
event-listener.name=kafka
kafka.bootstrap.servers=kafka1:9092,kafka2:9092,kafka3:9092
kafka.event-listener.topic=trino-query-events
```

A downstream Spark job can consume and land events into an Iceberg observability table:

```python
spark.readStream.format("kafka") \
  .option("kafka.bootstrap.servers", "kafka1:9092,...") \
  .option("subscribe", "trino-query-events") \
  .load() \
  .select(col("value").cast("string").alias("event_json")) \
  .writeStream.mode("append") \
  .option("checkpointLocation", "/path/to/checkpoint") \
  .toTable("iceberg.observability.trino_query_events")
```

**For MySQL (simple operational footprint):**

```properties
event-listener.name=mysql
mysql.event-listener.connection-url=jdbc:mysql://mysql-host:3306/trino_audit
mysql.event-listener.connection-user=trino_audit_user
mysql.event-listener.connection-password=${MYSQL_PASSWORD}
mysql.event-listener.table=query_log
```

The MySQL listener auto-creates a table with columns for all event fields — immediately SQL-queryable without additional tooling.

> **Note**: there is NO built-in file event listener (`event-listener.name=file` does not ship out of the box). For writing to local disk, point the HTTP listener at a sidecar (Fluent Bit, Vector).

---

## User Identity in Query Logs — JWT + OPA Context

Your production stack uses JWT tokens for authentication and OPA for authorization. Here's how identity flows:

1. User obtains a JWT from your auth service and passes it to Trino in the HTTP header.
2. Trino validates the JWT and extracts the user identity (typically the `sub` claim).
3. OPA evaluates the query against authorization policies using that identity.
4. The `user` column in `system.runtime.queries` and in every `QueryCompletedEvent` is the JWT-extracted identity.

**Result for compliance auditing**: IT and legal can query "all queries run by alice@company.com on 2026-05-15" using the `user` column in your persisted event store.

---

## Finding Expensive Queries Using System Tables (Live)

Before you configure persistence, use these recipes on live in-memory queries:

**Top 50 by bytes scanned from MinIO:**

```sql
SELECT
  q.query_id,
  q.query,
  q.user,
  SUM(t.physical_input_bytes) / 1e9      AS input_gb,
  SUM(t.split_cpu_time_ms)   / 1000.0    AS cpu_sec,
  q.created,
  q.end
FROM system.runtime.queries q
JOIN system.runtime.tasks t ON q.query_id = t.query_id
WHERE q.state = 'FINISHED'
GROUP BY q.query_id, q.query, q.user, q.created, q.end
ORDER BY input_gb DESC
LIMIT 50;
```

**High-frequency dashboard queries (the compute killers):**

```sql
SELECT
  q.query,
  COUNT(*)                                          AS run_count,
  ROUND(AVG(t_agg.input_gb), 2)                     AS avg_input_gb,
  ROUND(COUNT(*) * AVG(t_agg.input_gb), 1)          AS total_gb_per_period
FROM system.runtime.queries q
JOIN (
  SELECT query_id, SUM(physical_input_bytes) / 1e9 AS input_gb
  FROM system.runtime.tasks
  GROUP BY query_id
) t_agg ON q.query_id = t_agg.query_id
WHERE q.state = 'FINISHED'
GROUP BY q.query
HAVING COUNT(*) > 10
ORDER BY total_gb_per_period DESC
LIMIT 20;
```

A single 5 GB query is fine. The same query running 200 times a day is 1 TB of daily I/O — the optimization target.

---

## Persistent Query History — SQL Examples for Compliance and Optimization

Once events are persisted to an Iceberg table or MySQL, run against the durable store:

**Compliance audit: who ran what on a specific date:**

```sql
SELECT
  created_at,
  user,
  query_text,
  state,
  bytes_scanned / 1e9                            AS gb_scanned,
  EXTRACT(EPOCH FROM completed_at - created_at) / 60.0  AS duration_min
FROM iceberg.observability.trino_query_events
WHERE created_at >= TIMESTAMP '2026-05-15 00:00:00'
  AND created_at <  TIMESTAMP '2026-05-16 00:00:00'
ORDER BY created_at;
```

**Top users by weekly compute:**

```sql
SELECT
  user,
  COUNT(*)                    AS query_count,
  SUM(bytes_scanned) / 1e9    AS total_gb,
  ROUND(AVG(bytes_scanned) / 1e9, 2)  AS avg_gb_per_query
FROM iceberg.observability.trino_query_events
WHERE created_at >= CURRENT_DATE - INTERVAL '7' DAY
  AND state = 'FINISHED'
GROUP BY user
ORDER BY total_gb DESC
LIMIT 20;
```

**Top 10 slowest queries:**

```sql
SELECT
  query_id,
  user,
  query_text,
  EXTRACT(EPOCH FROM completed_at - created_at)  AS duration_sec,
  bytes_scanned / 1e9                            AS gb_scanned,
  created_at
FROM iceberg.observability.trino_query_events
WHERE created_at >= CURRENT_DATE - INTERVAL '7' DAY
  AND state = 'FINISHED'
ORDER BY duration_sec DESC
LIMIT 10;
```

**Failed queries (reliability audit):**

```sql
SELECT
  query_id, user, query_text, error_code, error_message, created_at
FROM iceberg.observability.trino_query_events
WHERE created_at >= CURRENT_DATE - INTERVAL '7' DAY
  AND state = 'FAILED'
ORDER BY created_at DESC;
```

---

## Next Steps

1. **Set up an event listener now** — HTTP → sidecar → Iceberg, Kafka → Iceberg, or MySQL. Pick whichever fits your existing stack.
2. **Query live `system.runtime.queries` daily** during the first week to understand your baseline.
3. **After one week of persisted history**, run the high-frequency recipe to find dashboard refresh storms worth optimizing with rollup tables or caching.
4. **Surface top consumers to your team weekly** — visibility drives optimization.
