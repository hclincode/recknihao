# Iter124 Q1 — Answer

**Question**: We're getting customer complaints that their analytics dashboard is slow, and we're trying to figure out if it's one particular bad query dragging things down or something else. In Postgres I'd just run `SELECT * FROM pg_stat_activity` and see what's running right now, or look at `pg_stat_statements` for historically slow queries. Does Trino have anything like that? Where do I actually look to find what queries are running, who ran them, and how long they took?

---

## Finding Running and Slow Queries on Trino 467

Trino doesn't have a perfect equivalent to `pg_stat_activity` and `pg_stat_statements`, but it does have two system tables that work together to give you the visibility you need. The catch is understanding their limits — they're **ephemeral and in-memory**, which affects your diagnostics strategy.

### The two system tables (Trino 467 schema)

**`system.runtime.queries`** — one row per query, holds the SQL text and lifecycle metadata. Critical columns:
- `query_id`, `state` (QUEUED, RUNNING, FINISHED, FAILED)
- `query` — the **complete SQL text**
- `user`, `source` (which principal and client ran it)
- `queued_time_ms`, `analysis_time_ms`, `planning_time_ms` — phase timings
- `created`, `started`, `end` — timestamps (note: it's `end`, not `end_time`)

**`system.runtime.tasks`** — one row per task per stage per worker. Holds the byte and CPU counters:
- `physical_input_bytes` — bytes actually read from MinIO
- `split_cpu_time_ms` — CPU time (NOT `cpu_time_ms`)
- `processed_input_bytes`, `output_bytes`, `output_rows`
- `query_id`, `node_id`, `state`

The key insight: **you must JOIN them** to get a useful view. The SQL text lives only on `queries`; the cost metrics live only on `tasks`. They're strict about column names — if you write `cpu_time_ms` instead of `split_cpu_time_ms`, the query fails with a "Column cannot be resolved" error.

### Real-time check: what's running right now?

This is your "analytics dashboard is slow, something's wrong *now*" query. Open the Trino UI at `http://trino-coordinator:8080/ui/queries` first — it gives you a quick visual of concurrency. For SQL:

```sql
SELECT
  query_id,
  user,
  state,
  query,
  CAST(queued_time_ms AS BIGINT) / 1000.0 AS queued_sec,
  CAST(planning_time_ms AS BIGINT) / 1000.0 AS planning_sec,
  CAST(DATE_DIFF('millisecond', started, now()) AS BIGINT) / 1000.0 AS elapsed_sec
FROM system.runtime.queries
WHERE state IN ('QUEUED', 'RUNNING')
ORDER BY elapsed_sec DESC;
```

This shows you:
- Any queries stuck in QUEUED (means workers are saturated)
- How long each query has been running
- The actual SQL so you can recognize your dashboard queries

**Normal** on a healthy cluster: 5–20 concurrent queries, most finishing in seconds. **Red flags**: anything QUEUED for > 10 seconds, or any query > 2 minutes old still RUNNING.

### Top expensive queries by bytes scanned

Once you know something is slow, find out which queries cost the most. This ranks by bytes read from MinIO:

```sql
SELECT
  q.query_id,
  q.query,
  q.user,
  SUM(t.physical_input_bytes) / 1e9 AS input_gb,
  SUM(t.split_cpu_time_ms) / 1000.0 AS cpu_sec,
  q.created,
  q.end
FROM system.runtime.queries q
JOIN system.runtime.tasks t ON q.query_id = t.query_id
WHERE q.state = 'FINISHED'
GROUP BY q.query_id, q.query, q.user, q.created, q.end
ORDER BY input_gb DESC
LIMIT 50;
```

If the same query runs repeatedly (like a dashboard refreshing every 30 seconds), you'll see it multiple times. That's your signal to cache or pre-aggregate.

### Finding the high-frequency culprit

A single 5 GB query is fine. The same query running 200 times a day is a 1 TB daily I/O tax for one dashboard:

```sql
SELECT
  q.query,
  COUNT(*) AS run_count,
  ROUND(AVG(t_agg.input_gb), 2) AS avg_input_gb,
  ROUND(COUNT(*) * AVG(t_agg.input_gb), 1) AS total_gb_per_period
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

The `HAVING COUNT(*) > 10` filters out one-off ad-hoc queries. The `total_gb_per_period` column tells you the total work the cluster did for each query pattern.

### The critical caveat: system.runtime.* is ephemeral

**`system.runtime.queries` and `system.runtime.tasks` are in-memory views that exist ONLY on the running coordinator.** Every coordinator restart wipes them clean. The retention window is also bounded by `query.max-history` (default 100 queries) and `query.min-expire-age` (default 15 minutes) — older entries get evicted regardless.

For any historical analysis beyond a few hours — cost retrospectives, "what happened at 3 AM last week?" — **you must configure a Trino event listener** to persist queries to durable storage.

Trino ships with three built-in event listener plugins:
- **File event listener** (`event-listener.name=file`) — appends JSON to a local coordinator disk file. Simplest.
- **HTTP event listener** (`event-listener.name=http`) — POSTs each query completion event to an HTTP endpoint.
- **Kafka event listener** (`event-listener.name=kafka`) — publishes events to a Kafka topic. Best for high-throughput setups.

Configure in `etc/event-listener.properties` on the coordinator. **Without this, you're blind beyond ~100 queries and ~15 minutes.** Once persisted into an Iceberg observability table, you can run the same recipes above against the persistent table and see patterns over days.

### Diagnosing a slow query with EXPLAIN

Once you've identified a specific slow query:

```sql
-- Plan only — does NOT execute the query
EXPLAIN (TYPE DISTRIBUTED)
SELECT tenant_id, COUNT(*) AS events
FROM iceberg.analytics.feature_usage
WHERE event_date >= CURRENT_DATE - INTERVAL '90' DAY
GROUP BY tenant_id;
```

Look at the `Files:` count — the most actionable number. If you're scanning 4,860 files instead of ~90 (for 90 days with daily partitions), your partition pruning is broken. If files are 50x what you expect, compaction fell behind and you have thousands of tiny files.

**Note**: `EXPLAIN ANALYZE` actually executes the query at full cost. Use `EXPLAIN (TYPE DISTRIBUTED)` for a plan-only check.

### On-prem cost thinking

On your stack (k8s + MinIO, already paid for), the marginal dollar cost of one extra query is effectively zero. What you actually pay for is k8s vCPU/RAM utilization and queueing latency. A query that's "free" in isolation but blocks 20 other queries for 5 minutes still has a real cost — experienced by users as slowness.

Optimize by first finding the **high-frequency, high-byte** queries with the recipes above, then decide: cache it, pre-aggregate it, or add a partition filter to prune better.

### Verification recipe for your stack

1. **Right now**: `SELECT count(*) FROM system.runtime.queries WHERE state = 'RUNNING'` — current concurrency. Healthy: under 20.
2. **Last hour**: Top expensive queries JOIN recipe — shows what actually costs CPU and I/O.
3. **Patterns**: High-frequency recipe — if one query appears 50+ times, that's your target.
4. **Plan check**: `EXPLAIN (TYPE DISTRIBUTED) <slow_query>` — look at Files count. If 10x expected, partition pruning is broken.
5. **For lasting visibility**: Configure an event listener to land query completion events in an Iceberg observability table.
