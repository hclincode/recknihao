# Iter 222 Q2 — Federation Monitoring: Detecting When Trino Is Hammering a Source Database

## Answer

To detect whether a Trino federation query is hammering your source databases before customers notice, you need visibility at four layers: Trino itself (query-level), your source database (connection and query activity), your connection pooler (if one exists), and durable logging. Here's what to monitor at each layer and how to set up safety valves.

---

## Trino-Side Monitoring: Finding Active Federation Queries

### system.runtime.queries to identify federation traffic

Query Trino's in-memory query table to find active federation queries **right now**:

```sql
-- Active federation queries touching billing_mysql
SELECT
  query_id,
  "user",                                           -- MUST be double-quoted
  source,
  query,
  state,
  date_diff('minute', started, current_timestamp) AS running_minutes
FROM system.runtime.queries
WHERE query LIKE '%billing_mysql%'
  AND state = 'RUNNING'
ORDER BY started ASC;
```

**Key columns to watch:**
- **`state`**: `RUNNING` means active now. If state is `RUNNING` and `running_minutes > 30`, it's a candidate for killing.
- **`source`**: tells you which dashboard/tool issued it (set via JDBC `?source=name` or HTTP header). Use this to attribute blame.
- **`query`**: the full SQL — if it lacks a WHERE clause or has a function-based predicate (e.g., `WHERE LOWER(status) = 'active'`), that's a sign predicate pushdown failed and the whole table is streaming over JDBC.

**Critical caveat**: `system.runtime.queries` is **ephemeral** — it lives in coordinator memory and is wiped on restart. After a time window, old entries are evicted. For durable historical tracking, you need a Trino event listener (see below).

### system.runtime.tasks to track bytes flowing from source databases

Cross-reference the queries above with the tasks table to see how much data is actually moving:

```sql
-- For a specific federation query: how many bytes is the MySQL scan pulling?
SELECT
  query_id,
  stage_id,
  SUM(physical_input_bytes) / 1e9 AS input_gb,
  SUM(split_cpu_time_ms) / 1000.0 AS cpu_sec,
  state
FROM system.runtime.tasks
WHERE query_id = '20260527_143012_00042_abcde'  -- replace with actual query_id
GROUP BY query_id, stage_id, state;
```

**Watch for**: If `physical_input_bytes` is close to your entire MySQL table size (e.g., you expected 1 GB, you're seeing 100 GB), **predicate pushdown failed** — the query is pulling the full table over JDBC despite having a WHERE clause. This is the smoking gun for runaway federation queries.

---

## Trino Event Listener: Durable Federation Query Logging

Because `system.runtime.queries` is ephemeral, **set up a Trino event listener** to persist query metadata to durable storage. This is the only way to answer "which queries hit `billing_mysql` last week?" without coordinator restart losing the data.

The event listener ships `QueryCompletedEvent` records (one per query) to external storage. Configure in `etc/http-event-listener.properties` on the coordinator:

```properties
event-listener.name=http
http-event-listener.connect-ingest-uri=http://audit-collector:8080/events
http-event-listener.log-completed=true
http-event-listener.log-created=false
```

Register it in `etc/config.properties`:
```properties
event-listener.config-files=etc/http-event-listener.properties
```

Once events land in durable storage, query the audit log to find expensive federation queries:

```sql
SELECT
  query_id,
  query_text,
  execution_time_ms,
  physical_input_bytes / 1e9 AS input_gb,
  created_at
FROM iceberg.observability.query_events
WHERE created_at > NOW() - INTERVAL '24' HOUR
  AND query_text LIKE '%billing_mysql%'
ORDER BY physical_input_bytes DESC
LIMIT 50;
```

---

## MySQL-Side Monitoring: SHOW PROCESSLIST

When a Trino federation query is running, MySQL sees one or more **JDBC connections** actively executing SQL. Monitor them:

```sql
-- On the MySQL replica:
SHOW FULL PROCESSLIST;
```

**What to look for**:
- **Command**: should be `Query` (SQL is executing) or `Sleep` (connection idle). Many `Sleep` entries under the `trino_reader` user = connections pooled but idle.
- **Time**: how long has this statement been running? Long-running statements mean either the query is legitimately expensive, or `statement_timeout` is not set.
- **Info**: the actual SQL MySQL is executing. **Look for a WHERE clause:** if you see `SELECT * FROM invoices` with no WHERE, predicate pushdown failed — the connector sent an unfiltered query.

Connection count alert:
```sql
SELECT COUNT(*) FROM INFORMATION_SCHEMA.PROCESSLIST
WHERE USER = 'trino_reader';
```

**Alert threshold**: if `COUNT(*) > 20` (or whatever fraction of your pool you've budgeted for Trino), federation queries are consuming a growing share of connections — investigate before the database falls over.

---

## PostgreSQL-Side Monitoring: pg_stat_activity

On a Postgres replica, use the native view for richer diagnostics:

```sql
-- Live: what Trino is running right now
SELECT
  pid,
  query_start,
  state,
  query,
  wait_event,
  wait_event_type
FROM pg_stat_activity
WHERE usename = 'trino_reader'
ORDER BY query_start ASC;
```

**Key fields**:
- **`query_start`**: when did the statement begin?
- **`state`**: `active` (SQL executing), `idle in transaction` (waiting for next statement), `idle` (connection open, no transaction).
- **`query`**: the SQL. Compare to what you submitted from Trino — if Trino rewrote it to push a WHERE clause, predicate pushdown happened.
- **`wait_event`**: if non-null, the query is blocked (lock, I/O, replication). High `wait_event` counts signal a bottleneck.

**Alert threshold**: any query from `trino_reader` running > 5 minutes should be investigated.

---

## PgBouncer Monitoring: Connection Pool Saturation

If you've deployed **PgBouncer** in front of Postgres, monitor pool state:

```bash
# Connect to PgBouncer admin console:
psql -h pgbouncer.app.svc.cluster.local -p 6432 pgbouncer
```

```sql
-- Inside PgBouncer console:
SHOW POOLS;   -- shows current_connections vs pool size
SHOW CLIENTS; -- shows client connections waiting for a pool slot
```

**Alert threshold**: `waiting_clients > 5` for more than 1 minute = too many federation queries, too few pool slots. Action: lower `hardConcurrencyLimit` in Trino resource groups or raise PgBouncer's `default_pool_size` (then raise Postgres role `CONNECTION LIMIT` to match).

---

## What to Alert On: Thresholds and Safety Valves

### Recommended alert thresholds

| Signal | Threshold | Action |
|--------|-----------|--------|
| **MySQL: active Trino connections** | > 20 (or your budgeted ceiling) | Investigate; likely missing `statement_timeout` or a stuck query. |
| **Trino `system.runtime.queries`: RUNNING > 30 min** | Any query | Kill with `CALL system.runtime.kill_query(query_id => '...')`. |
| **Event listener: `physical_input_bytes` near full table size** | > 90% of table size | Predicate pushdown failed — run `EXPLAIN (TYPE DISTRIBUTED)` to diagnose. |
| **PgBouncer: `waiting_clients` > 0** | Sustained > 1 minute | Lower Trino `hardConcurrencyLimit` or raise PgBouncer `default_pool_size`. |

### Safety Valves (Defense in Depth)

Because **OSS Trino 467 has no native JDBC connection pool** for the MySQL or PostgreSQL connector, layer four separate limits:

**1. PgBouncer (the network pool)**
```ini
pool_mode = transaction
default_pool_size = 50
max_client_conn = 1000
```

**2. Postgres/MySQL role-level cap**
```sql
-- PostgreSQL:
ALTER ROLE trino_reader CONNECTION LIMIT 50;
```
This is a hard stop enforced by the database itself.

**3. Trino resource groups (cap concurrent queries)**
```json
{
  "rootGroups": [
    {
      "name": "federation",
      "hardConcurrencyLimit": 10,
      "softMemoryLimit": "30%",
      "maxQueued": 50
    }
  ],
  "selectors": [
    {
      "source": ".*federation.*",
      "group": "federation"
    }
  ]
}
```

**Critical**: The `source` field requires clients to set `?source=federation-queries` in the JDBC URL or `X-Trino-Source` header. If clients don't set it, the selector doesn't match and queries bypass the limit.

**4. Database `statement_timeout` (backstop)**
```sql
-- PostgreSQL replica:
ALTER ROLE trino_reader SET statement_timeout = '300000';  -- 5 min in ms
```

Any query running > 5 minutes gets cancelled by the database itself, even if Trino's limits didn't catch it.

---

## In Summary: The Monitoring Stack

**Real-time (live triage):**
- Trino UI (`/ui/queries`) — see active queries and which catalog they touch
- `system.runtime.queries` + `system.runtime.tasks` — find runaway queries by bytes scanned and runtime
- MySQL `SHOW FULL PROCESSLIST` / Postgres `pg_stat_activity` — see the actual SQL executing
- PgBouncer `SHOW POOLS` / `SHOW CLIENTS` — detect pool saturation

**Historical (retrospective):**
- Trino event listener (persisted to Iceberg/logging stack) — "which queries touched `billing_mysql` last week and how expensive were they?"

**Safety valves (prevent incidents):**
- PgBouncer `default_pool_size` (network pool cap)
- Database role `CONNECTION LIMIT` (hard database-enforced cap)
- Trino resource group `hardConcurrencyLimit` (query admission control)
- Database `statement_timeout` (backstop kill)

With these four layers in place, a badly-written federation query cannot exhaust your database connections or run indefinitely. You'll see it coming via `system.runtime.*` or the event listener and can kill it before it causes an incident.
