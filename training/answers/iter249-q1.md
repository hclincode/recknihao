# Iter249 Q1 — Coordinator Debug Logging for Slow Federated Queries

## Answer

Your situation—45 seconds in Trino vs 3 seconds in Postgres—is a classic federated-query performance problem. The root cause is almost always one of these: predicate pushdown failure (Trino fetches too many rows from Postgres), dynamic filtering not firing, or missing partition pruning on the Iceberg side. Here's how to diagnose and fix it.

### 1. Enable JDBC Debug Logging to See What SQL Trino Sends to Postgres

This is the fastest diagnostic. Add a single line to `etc/log.properties` on your **coordinator pod**:

```properties
# etc/log.properties
io.trino.plugin.jdbc=DEBUG
```

Restart the coordinator. Then re-run your slow query. The debug logs will appear in `var/log/server.log` with lines like:

```
io.trino.plugin.jdbc.DefaultJdbcMetadata - Executing query: SELECT id, accounts.* FROM accounts WHERE plan_type = 'enterprise'
```

This shows you **exactly what SQL Trino sent to Postgres**. If you see a bare `SELECT * FROM accounts` with no WHERE clause, your predicate didn't push down—that's your problem.

**Important**: This setting is very verbose and logs every JDBC call. Only leave it on during diagnosis, then revert to `INFO` and restart the coordinator.

For Kubernetes, the coordinator logs typically ship to your centralized logging system (Loki, OpenSearch, etc.) so check there if `var/log/server.log` is hard to access.

### 2. Use EXPLAIN (TYPE DISTRIBUTED) to Verify Predicate Pushdown

Don't use `EXPLAIN ANALYZE` first—it re-runs the query, costing you 45 seconds. Instead, run the plan-only form:

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT e.*, a.plan_type
FROM iceberg.analytics.events e
JOIN postgres_catalog.public.accounts a ON e.account_id = a.id
WHERE a.plan_type = 'enterprise'
  AND e.event_date >= DATE '2026-05-20';
```

Look for **two specific signals**:

**Signal 1: Predicate position in the Postgres scan**

- **SUCCESS**: The WHERE clause appears **inside** the `TableScan` node as `constraint on [plan_type]`. This means Postgres is filtering server-side.
- **FAILURE**: A `ScanFilterProject` or `Filter` node sits **above** the `TableScan`, with the predicate inside it. This means Trino fetched all rows from Postgres then filtered locally—disaster.

**Signal 2: Dynamic filtering on the Iceberg side**

Look for `dynamicFilters = {...}` annotations on the Iceberg TableScan. If it's present, dynamic filtering is wired up.

### 3. Run EXPLAIN ANALYZE to Measure What Actually Happened

```sql
EXPLAIN ANALYZE (TYPE DISTRIBUTED)
SELECT e.*, a.plan_type
FROM iceberg.analytics.events e
JOIN postgres_catalog.public.accounts a ON e.account_id = a.id
WHERE a.plan_type = 'enterprise'
  AND e.event_date >= DATE '2026-05-20';
```

Look at the **Postgres TableScan** operator's metrics:

| Metric | What it tells you |
|---|---|
| `Input: N rows` | How many rows Postgres returned over JDBC. If this equals your full accounts table size, predicate didn't push down. |
| `Physical Input: XXX MB` | Total bytes received from Postgres. Matches table size = full table scan over the wire. |

**Pushdown failing** looks like: `ScanFilterProject[filter = (plan_type = 'enterprise')]` above `TableScan` with `Input: 5200000 rows`.

### 4. Common Causes and Fixes

**Cause A: VARCHAR range predicates don't push down by default**

PostgreSQL connector supports equality (`=`), IN-lists, and LIKE prefix. Range on VARCHAR (`WHERE plan_type > 'a'`) does NOT push by default. To enable:

```properties
# etc/catalog/postgres_catalog.properties
postgresql.experimental.enable-string-pushdown-with-collate=true
```

**Cause B: Iceberg partition pruning failed**

If your WHERE clause wraps the partition column in a function (`DATE(event_timestamp)`), pruning is defeated. Match the predicate shape to the partition transform exactly.

**Cause C: Dynamic filtering timeout**

Raise the wait-timeout so the DF IN-list has time to build before Iceberg starts scanning:

```properties
# etc/catalog/iceberg.properties
dynamic-filtering.wait-timeout=20s
```

Or per-session: `SET SESSION iceberg.dynamic_filtering_wait_timeout = '20s';`

### 5. Ground-Truth Check: Postgres Slow Log

Enable slow logging on your read replica to see the actual SQL Trino sent:

```sql
ALTER SYSTEM SET log_min_duration_statement = 0;
SELECT pg_reload_conf();
```

If you see `SELECT * FROM accounts` with no WHERE, pushdown failed.

### 6. Kubernetes Log Access

```bash
kubectl logs -n <trino_namespace> <coordinator_pod_name> | grep "io.trino.plugin.jdbc"
```

### Most Likely Culprit

**45 seconds → 3 seconds** ratio (~15x) typically means Postgres is returning most of its table over JDBC (predicate didn't push). Start with the JDBC debug log or plain `EXPLAIN (TYPE DISTRIBUTED)` and check the `Input:` row count in EXPLAIN ANALYZE.
