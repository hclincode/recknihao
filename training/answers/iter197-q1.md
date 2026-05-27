# Iter 197 Q1 — Federation Monitoring and Observability

## Answer

Your experience — discovering a 4-hour replica lag with zero visibility from Trino — is a real operational gap. You need to instrument three separate layers:

1. **What Trino is sending to Postgres** (query execution visibility)
2. **How Postgres is handling it** (push-down confirmation)
3. **The health of the replica itself** (replication lag — external to Trino)

---

### Part 1: Detecting Failed Push-Down (via EXPLAIN)

When a federated query runs, you need to know: did the WHERE clause push down to Postgres, or did Trino pull the whole table?

Use `EXPLAIN (TYPE DISTRIBUTED)` before running production federation queries:

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT * FROM app_pg.public.users
WHERE status = 'active' AND plan = 'enterprise';
```

**Push-down SUCCEEDED**: The predicate appears **inside** the `TableScan` constraint:
```
TableScan [table=app_pg:public.users]
    constraint on (status, plan): (status = 'active' AND plan = 'enterprise')
```

**Push-down FAILED**: A `ScanFilterProject` or `Filter` node sits **above** the `TableScan`, carrying the predicate outside. Trino fetched the entire table over the network.

**Real-world check**: Enable Postgres slow-query logging (`log_min_duration_statement=0` temporarily), run the Trino query, and check what SQL Postgres actually received. If it shows `SELECT * FROM users` with no WHERE clause, push-down failed.

---

### Part 2: Monitoring Trino Query Execution

**A. Live on the replica: `pg_stat_activity`**
```sql
-- Run on your Postgres read replica
SELECT pid, query_start, state, query, wait_event
FROM pg_stat_activity
WHERE usename = 'trino_reader'
ORDER BY query_start DESC;
```
Shows the actual SQL Trino sent to Postgres right now. Live-only — disappears when the query finishes.

**B. Live in Trino: `system.runtime.queries`**
```sql
SELECT query_id, "user", source, query, state,
       created, "end"
FROM system.runtime.queries
WHERE query LIKE '%app_pg%'
  AND state = 'FINISHED'
ORDER BY created DESC
LIMIT 50;
```
Note: `"user"` must be double-quoted (Trino parser treats unquoted `user` as a builtin). This is in-memory and ephemeral — rows disappear after coordinator restart or ~15 minutes.

**C. Persistent: Trino HTTP event listener**

For durable query history, configure Trino's event listener to ship query metadata to an external sink:

```properties
# etc/event-listener.properties
event-listener.type=http
http-event-listener.connect-ingest-uri=http://vector-svc.observability.svc.cluster.local:8686/
```

Ship to OpenSearch or Loki. The `QueryCompletedEvent` includes full SQL text, wall-clock execution time, bytes scanned, catalogs/tables touched, and error info.

**D. Persistent: OPA decision log**

Your existing OPA auth log captures every query touching `app_pg` catalog. Enable:
```yaml
decision_logs:
  console: true
```
Ship to OpenSearch/Loki via sidecar. Key fields: `input.action.resource.catalog.name` (which catalog), `input.context.identity.user` (who ran it).

---

### Part 3: Detecting Replica Lag (THE MISSING PIECE)

**This is external to Trino.** Trino will silently serve stale data without any log entry. Monitor the replica directly.

**On the primary Postgres:**
```sql
SELECT client_addr, state,
       EXTRACT(EPOCH FROM replay_lag) as replay_lag_sec
FROM pg_stat_replication
WHERE usename = 'replication_role';
```

**On the replica itself:**
```sql
SELECT now() - pg_last_xact_replay_timestamp() as replay_lag;
```

`replay_lag` is the true staleness metric — how far behind the replica is in applying writes from the primary.

**Alert thresholds:**
- WARNING: replay lag > 60 seconds
- CRITICAL: replay lag > 5 minutes

---

### Part 4: Alert Strategy

| Alert | What to Monitor | Threshold | Why |
|---|---|---|---|
| **Replica lag (CRITICAL)** | `pg_last_xact_replay_timestamp()` on replica | > 5 minutes | Catches stale-data before users see it |
| **Push-down failure (HIGH)** | Event listener: queries where Physical Input ≈ full-table size but filtered rows << input rows | > 10% of federation queries | Postgres replica gets crushed |
| **Postgres statement timeouts (HIGH)** | Postgres logs for `ERROR: canceling statement due to statement timeout` from `trino_reader` | Any occurrence | Query too expensive for replica |
| **JDBC socket timeouts (MEDIUM)** | Trino worker logs for `java.net.SocketTimeoutException: Read timed out` | > 5 per hour | Postgres went silent mid-query |

---

### Configuration to Add Now

**On your Postgres read replica:**
```sql
-- 5-minute statement timeout for all Trino queries
ALTER ROLE trino_reader SET statement_timeout = '300000';  -- milliseconds
SELECT pg_reload_conf();
```

**In your Trino catalog file (`etc/catalog/app_pg.properties`):**
```properties
connection-url=jdbc:postgresql://pgbouncer.app.svc.cluster.local:6432/appdb?defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10&prepareThreshold=0
```

**In `etc/config.properties`:**
```properties
query.max-execution-time=10m
query.max-run-time=15m
```

### One-Query Check to Run Right Now

```sql
-- Run on your Postgres replica to baseline current lag
SELECT 
  now() - pg_last_xact_replay_timestamp() as replica_lag,
  pg_last_wal_receive_lsn() as last_receive_lsn,
  pg_last_wal_replay_lsn() as last_replay_lsn;
```

If this shows lag > 60 seconds on a healthy day, investigate your replication setup. Trino will not tell you about it.
