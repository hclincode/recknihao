# Iter 231 Q2 — How to Find Active Trino Queries Hitting MySQL

## Answer

### The Quick Check: Active Queries Right Now

Start with the Trino Web UI, which is the fastest visual check:

```
http://trino-coordinator:8080/ui/queries
```

Look for queued queries, long-running queries (>2 minutes), and query text with resource consumption.

### Finding Running Queries via SQL (system.runtime.queries)

The `system.runtime.queries` table shows all in-flight and recently completed queries:

```sql
SELECT
  query_id,
  "user",                           -- CRITICAL: must be double-quoted
  source,
  query,
  state,
  created,
  started,
  date_diff('minute', started, current_timestamp) AS running_minutes
FROM system.runtime.queries
WHERE state = 'RUNNING'
ORDER BY started ASC;
```

**Critical detail**: `"user"` must be double-quoted. Unquoted `user` is parsed as the `current_user()` builtin function, which silently returns the session user instead of the column value — a subtle bug that looks like data corruption but is a syntax issue.

### Identifying Which Queries Touch MySQL

**Level 1: Filter by MySQL catalog name in the SQL text**

```sql
SELECT query_id, "user", source, query, state
FROM system.runtime.queries
WHERE query LIKE '%billing_mysql%'
  AND state IN ('RUNNING', 'FINISHED')
ORDER BY created DESC
LIMIT 20;
```

Replace `billing_mysql` with your actual MySQL catalog name. This finds queries that reference MySQL tables.

**Important caveat**: `LIKE` matching can produce false positives if the catalog name appears in a comment or string literal. For durable historical analysis beyond what `system.runtime.*` retains in memory, configure a Trino event listener to persist `QueryCompletedEvent` records.

**Level 2: Resource consumption per task**

Once you've identified a candidate query, join the two system tables to see CPU and I/O per stage:

```sql
SELECT
  q.query_id,
  q."user",
  q.query,
  t.stage_id,
  t.node_id,
  SUM(t.physical_input_bytes) / 1e9        AS input_gb,
  SUM(t.split_cpu_time_ms) / 1000.0        AS cpu_sec,
  COUNT(*)                                   AS task_count
FROM system.runtime.queries q
JOIN system.runtime.tasks t ON q.query_id = t.query_id
WHERE q.query LIKE '%billing_mysql%'
  AND q.state = 'RUNNING'
GROUP BY q.query_id, q."user", q.query, t.stage_id, t.node_id
ORDER BY input_gb DESC;
```

The stage with the highest `input_gb` hitting your MySQL catalog is the bottleneck.

### Top-Level View of Most Expensive Running Queries

```sql
SELECT
  q.query_id,
  q."user",
  q.source,
  substring(q.query, 1, 100) AS query_preview,
  SUM(t.physical_input_bytes) / 1e9       AS total_input_gb,
  SUM(t.split_cpu_time_ms) / 1000.0       AS total_cpu_sec,
  q.state,
  date_diff('minute', q.started, current_timestamp) AS running_min
FROM system.runtime.queries q
JOIN system.runtime.tasks t ON q.query_id = t.query_id
WHERE q.state = 'RUNNING'
GROUP BY q.query_id, q."user", q.source, q.query, q.state, q.started
ORDER BY total_input_gb DESC
LIMIT 10;
```

Run this while MySQL CPU is spiking — the top rows are your candidates.

### Killing a Runaway Query

Once you've identified a culprit query by ID:

```sql
CALL system.runtime.kill_query(
  query_id => '<query_id>',
  message  => 'Killed — scanning entire MySQL table without filter'
);
```

### Limitations

1. **`system.runtime.*` is ephemeral** — lives only in the coordinator's memory. Default retention: `query.max-history` = 100 queries, `query.min-expire-age` = 15 minutes. For historical analysis ("what was eating MySQL last Tuesday?"), configure a Trino event listener to persist queries durably.

2. **No connector-level breakdown in system tables** — these tables don't tell you which stages touch which connectors. You infer it from the SQL text (does it mention the MySQL catalog name?) and task I/O patterns (does one stage have high input bytes?).

3. **EXPLAIN won't show connector traffic** — `EXPLAIN ANALYZE` shows the overall query plan but does not drill down to "this fragment sent 10 MB to MySQL." Infer from SQL text + byte consumption.
