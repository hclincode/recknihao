# Iter 217 Q2 — Trino JDBC Connection Pooling: How It Works and How to Fix Connection Exhaustion

## Answer

## Trino's PostgreSQL Connection Model: How It Actually Works (And Why You're Timing Out)

### The core problem: OSS Trino 467 has NO native connection pool

**This is the critical fact your team needs to understand first.** Open-source Trino 467's PostgreSQL connector does **not have built-in JDBC connection pooling**. Properties like `connection-pool.enabled`, `connection-pool.max-size`, and `connection-pool.max-connection-lifetime` that you might find in documentation do NOT exist in OSS Trino 467 — they belong to Starburst Enterprise (the commercial fork). If you copy-paste them into your catalog properties, Trino will silently ignore them and your connection problem will persist.

This is tracked in an open GitHub issue (trinodb/trino#15888) since January 2023.

### How Trino actually connects: one split = one connection

Here's the actual mental model you need:

**For a single non-partitioned PostgreSQL table:**
- Trino creates **exactly 1 split** (not one per worker)
- 1 split → 1 worker task → **1 JDBC connection**
- That single JDBC connection is opened on one worker and stays open for the entire query duration
- The other workers sit idle — only one does the read

**Connection count formula across concurrent queries:**
```
peak_postgres_connections = 
  max_concurrent_federation_queries 
  × avg_postgres_tables_per_query 
  × avg_splits_per_table
```

If you have 20 dashboard users running queries that each join 1 Postgres table, you open ~20 connections. At 30 concurrent users, you open ~30 connections. PostgreSQL has a default `max_connections=100`, but your application also uses some of those slots — so Postgres quickly rejects new Trino connections with "too many connections" errors.

### What happens when connections are exhausted

When Postgres runs out of connections:
- New connection attempts fail immediately with `FATAL: too many connections` or `FATAL: sorry, too many clients already`
- Trino workers receive `java.sql.SQLException: Connection refused` or similar
- The query fails and the user sees a timeout or connection error
- **There is no queue or wait at the Postgres level** — connections are rejected outright once `max_connections` is hit

### The four-layer solution

Because there is no Trino-side pool, you must bound connections using **four separate mechanisms that layer together**:

#### 1. PgBouncer in front of Postgres (the standard fix)

Deploy PgBouncer (a lightweight connection pooler) between Trino and Postgres. Trino opens many short-lived connections to PgBouncer; PgBouncer multiplexes them onto a small, bounded set of real Postgres connections.

**Required configuration for transaction-pooling mode** (recommended for Trino's read-only traffic):

```ini
# pgbouncer.ini
[pgbouncer]
pool_mode = transaction
max_client_conn = 1000           # How many client conns PgBouncer accepts (Trino side)
default_pool_size = 50           # Actual backend conns to Postgres per (db,user)
reserve_pool_size = 10
server_idle_timeout = 600
```

With `default_pool_size=50`, Postgres sees at most 50 connections from `trino_reader` no matter how many concurrent Trino queries are running.

**Critical caveat** — append `prepareThreshold=0` to your Trino catalog's JDBC URL:

```properties
# etc/catalog/app_pg.properties
connection-url=jdbc:postgresql://pgbouncer.app.svc.cluster.local:6432/appdb?prepareThreshold=0&socketTimeout=60&connectTimeout=10&defaultRowFetchSize=1000
```

**Why `prepareThreshold=0` is mandatory:** In transaction-pooling mode, PgBouncer routes successive transactions to potentially different backend connections. If Trino's JDBC driver prepares a statement on backend A and the next transaction lands on backend B, Postgres returns `ERROR: prepared statement does not exist`. Setting `prepareThreshold=0` disables server-side prepared statements entirely. Without this fix, federation will appear to work fine for the first few queries, then fail intermittently.

#### 2. Postgres role-level connection cap (defense in depth)

```sql
-- On the Postgres read replica:
ALTER ROLE trino_reader CONNECTION LIMIT 50;
```

Check usage:
```sql
SELECT count(*) FROM pg_stat_activity WHERE usename = 'trino_reader';
SELECT rolname, rolconnlimit FROM pg_roles WHERE rolname = 'trino_reader';
```

#### 3. Trino resource groups — cap concurrent federation queries

Create `etc/resource-groups.json` on the coordinator:

```json
{
  "rootGroups": [
    {
      "name": "federation",
      "softMemoryLimit": "30%",
      "hardConcurrencyLimit": 10,
      "maxQueued": 100,
      "schedulingPolicy": "fair"
    }
  ],
  "selectors": [
    {
      "user": ".*",
      "queryType": "SELECT",
      "source": ".*federation.*",
      "group": "federation"
    }
  ]
}
```

And `etc/resource-groups.properties`:
```properties
resource-groups.configuration-manager=file
resource-groups.config-file=etc/resource-groups.json
```

**Critical**: clients MUST set the `source` when submitting queries:
```
JDBC URL: jdbc:trino://coordinator:8080?source=federation-queries
HTTP header: X-Trino-Source: federation-queries
```

If clients don't set the source, queries bypass the `hardConcurrencyLimit=10` entirely.

#### 4. `statement_timeout` on the Postgres replica

```sql
ALTER ROLE trino_reader SET statement_timeout = '300000';  -- 5 minutes
SELECT pg_reload_conf();
```

Kills any statement that runs longer than the limit — prevents runaway federated queries from holding connections indefinitely.

### How to size these together — worked example

For a 20-worker Trino cluster with Postgres `max_connections=300` and the application using ~150:

| Layer | Setting | Value |
|---|---|---|
| PgBouncer | `default_pool_size` | 50 |
| Postgres role | `ALTER ROLE trino_reader CONNECTION LIMIT` | 50 |
| Trino resource group | `hardConcurrencyLimit` for federation | 10 |
| Postgres replica | `statement_timeout` | 5min |

### Diagnosing which layer is breaking

| Error message | Layer | Fix |
|---|---|---|
| `FATAL: too many connections` | Postgres native limit | Increase `max_connections` or fix PgBouncer config |
| `ERROR: canceling statement due to statement timeout` | Postgres `statement_timeout` | Query too expensive; add WHERE clause or raise timeout |
| `java.net.SocketTimeoutException: Read timed out` | JDBC `socketTimeout` | Postgres hung or slow; check replica health |
| `Query exceeded maximum time limit` | Trino's `query.max-execution-time` | Tune the query or move off federation |

### What does NOT work

Do NOT try:
- Adding `connection-pool.enabled` or `connection-pool.max-size` to your catalog file — OSS Trino silently ignores them
- Expecting one connection per worker — it's one connection per split
- Raising `hardConcurrencyLimit` to fix "too many connections" errors — the error comes from Postgres before resource groups can help
