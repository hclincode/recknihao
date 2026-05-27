# Iter 167 Q2 — Monitoring Which Trino Queries Hit Postgres

## Answer

Yes — Trino has built-in query monitoring tools that let you identify which queries are hitting the Postgres catalog. Here's how to use them.

## The core tool: `system.runtime.queries`

Trino exposes a system table called **`system.runtime.queries`** that lists every running and recently completed query on your cluster. It includes the **full SQL text** (`query` column), so you can filter by queries that reference your `app_pg` catalog:

```sql
-- See all queries referencing your Postgres catalog
SELECT
  query_id,
  user,
  state,
  created,
  query
FROM system.runtime.queries
WHERE query LIKE '%app_pg%'
ORDER BY created DESC
LIMIT 50;
```

This shows you which user ran the query, whether it's `RUNNING`, `QUEUED`, or `FINISHED`, and the full SQL — which tells you immediately if it joins Postgres and Iceberg or just hits one catalog.

## For load analysis: join with task telemetry

To measure how much load each Postgres query imposed, pair `system.runtime.queries` with `system.runtime.tasks`:

```sql
-- Postgres-touching queries ranked by I/O burden
SELECT
  q.query_id,
  q.user,
  q.query,
  SUM(t.physical_input_bytes) / 1e9 AS bytes_from_postgres_gb,
  SUM(t.split_cpu_time_ms) / 1000.0 AS cpu_seconds
FROM system.runtime.queries q
JOIN system.runtime.tasks t ON q.query_id = t.query_id
WHERE q.query LIKE '%app_pg%'
  AND q.state = 'FINISHED'
GROUP BY q.query_id, q.user, q.query
ORDER BY bytes_from_postgres_gb DESC
LIMIT 20;
```

## For your DBA: monitoring Postgres directly

The most authoritative view comes from the **Postgres read replica itself**. Log into the replica and run:

```sql
SELECT pid, query_start, state, query
FROM pg_stat_activity
WHERE usename = 'trino_reader'
ORDER BY query_start DESC;
```

This shows the **actual SQL Trino sent to Postgres** including any predicates that were pushed down. If you see a bare `SELECT col1, col2 FROM users` with no WHERE clause, predicate pushdown didn't happen and Trino pulled the entire table over the network.

## Important limitations

1. **`system.runtime.queries` is ephemeral** — it lives only in the coordinator's memory and retains only recent queries. Older entries are evicted after a short window. If you need historical data ("which queries hit Postgres over the last week?"), configure a **Trino event listener** to persist query completion events to durable storage.

2. **No native Postgres-specific column** — `system.runtime.queries` doesn't have a field like `catalogs_touched`. You identify Postgres queries by parsing the `query` text. A LIKE filter on the catalog name works for most cases.

3. **Trino UI** — for quick visual inspection, browse the Trino UI to see the query plan and which operators touched which catalogs. The text-based system table is more queryable at scale.

## Practical steps for your DBA

1. **Identify the slow Postgres query** via `pg_stat_activity` on the replica (shows real wall time and rows).
2. **Get the user and time from that output**, then query Trino's `system.runtime.queries` for the matching user and time window.
3. **Compare the actual Postgres SQL** (from `pg_stat_activity`) to the Trino query (from `EXPLAIN`) to understand where pushdown succeeded or failed.
4. **Set up persistent monitoring** — wire an event listener to ship query completion events to your observability system so you have historical data beyond the ephemeral window.
