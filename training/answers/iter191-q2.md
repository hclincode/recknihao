# Iter 191 Q2 — PgBouncer with Trino PostgreSQL Connector

## Answer

Yes, PgBouncer will absolutely help — and it's the standard fix for your exact problem. But there are specific details about transaction pooling modes and Trino's JDBC behavior that you must get right, or you'll hit a subtle failure that only appears after a few days of production use.

### The core issue: OSS Trino 467 has no connection pooling

OSS Trino 467's PostgreSQL connector has **zero built-in JDBC connection pooling**. Properties like `connection-pool.enabled`, `connection-pool.max-size`, and `connection-pool.max-connection-lifetime` that you might find in documentation are **Starburst Enterprise only** — not open-source Trino. If you add them to your catalog properties file, Trino silently ignores them and the pool doesn't exist.

### How Trino opens connections to Postgres

Each active federation query opens **one JDBC connection per non-partitioned Postgres table being scanned**. So with 50 concurrent analysts and a typical single-table federation query, Trino could open roughly 50 connections to Postgres. Scale that to multiple tables or partitioned scans, and you can easily hit Postgres's `max_connections` limit. Your read replica's `max_connections` is global across all roles, so you get "too many connections" errors once the ceiling is reached.

### PgBouncer is the fix — but use transaction pooling correctly

PgBouncer sits between Trino and Postgres and multiplexes many short-lived Trino connections onto a small, bounded set of real Postgres backend connections.

**Use `pool_mode = transaction` (not session).** Transaction pooling is safe for Trino because Trino's queries are read-only and don't rely on session-level state across statements. Transaction pooling multiplexes much more aggressively than session pooling (which would defeat the point).

**Minimal PgBouncer config example (on-prem k8s):**

```ini
[databases]
appdb = host=app-postgres-replica.app.svc.cluster.local port=5432 dbname=appdb

[pgbouncer]
listen_port = 6432
pool_mode = transaction
max_client_conn = 1000           # client side (Trino)
default_pool_size = 50           # actual backend connections to Postgres
server_idle_timeout = 600
```

With `default_pool_size=50`, Postgres sees at most 50 connections from Trino, **regardless of how many concurrent queries hit Trino**. PgBouncer handles the queueing.

### The critical JDBC parameter: `prepareThreshold=0`

**This is where most people fail after deploying PgBouncer.** You MUST add `prepareThreshold=0` to the JDBC URL.

Here's why: PostgreSQL server-side prepared statements are connection-scoped. When the PostgreSQL JDBC driver (pgjdbc) sees the same SQL executed 5+ times, it automatically issues a `PREPARE` statement to cache the plan on that connection. In transaction-pooling mode, PgBouncer may route the next transaction to a **different** backend connection — and that connection has never seen the `PREPARE`, so Postgres returns `ERROR: prepared statement "S_1" does not exist`.

The failure is delayed and intermittent: your federation will work fine for the first few queries, then after Trino runs the same query 5+ times and the driver promotes it to a prepared statement, you'll get random "prepared statement does not exist" errors scattered throughout the day.

**Fix: disable prepared statements entirely.** Set `prepareThreshold=0` in the JDBC URL:

```properties
# In etc/catalog/app_pg.properties:
connection-url=jdbc:postgresql://pgbouncer.app.svc.cluster.local:6432/appdb?prepareThreshold=0
```

Every query is sent as a simple query string with inline parameters. Small overhead per query (no plan reuse), but zero prepared-statement errors.

### Trino JDBC URL parameters for PgBouncer

Combine with other federation-performance parameters:

```properties
connection-url=jdbc:postgresql://pgbouncer.app.svc.cluster.local:6432/appdb?prepareThreshold=0&defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10
```

- `prepareThreshold=0` — disable prepared statements (mandatory for transaction pooling)
- `defaultRowFetchSize=1000` — batch rows from Postgres
- `socketTimeout=60` — fail-fast if Postgres goes silent
- `connectTimeout=10` — fail-fast if PgBouncer is down

### Defense in depth: layer three controls

**1. Postgres role-level connection cap:**

```sql
ALTER ROLE trino_reader CONNECTION LIMIT 50;
```

If PgBouncer misconfigures or something bypasses it, Postgres itself rejects the 51st connection from that role. Your application's own users (different role) are unaffected.

**2. Trino resource groups** — cap concurrent federation queries:

```json
{
  "rootGroups": [
    {
      "name": "federation",
      "hardConcurrencyLimit": 10,
      "maxQueued": 100
    }
  ]
}
```

At most 10 federation queries run at the same time. Combined with PgBouncer's 50-connection pool, you're well protected.

### Quick sizing example

20-worker cluster, 50 analysts, Postgres replica with `max_connections=300`:

| Layer | Setting | Value | Purpose |
|---|---|---|---|
| PgBouncer | `default_pool_size` | 50 | Actual Postgres backend connections |
| Postgres role | `CONNECTION LIMIT` | 50 | Hard cap on the role |
| Trino resource group | `hardConcurrencyLimit` | 10 | Max concurrent federation queries |

### Why NOT session pooling or statement pooling

**Session pooling** would avoid the prepared-statement issue, but you'd need almost as many backend connections as concurrent Trino clients — defeating PgBouncer's purpose. **Statement pooling** has even tighter constraints and is rare.

**Transaction pooling + `prepareThreshold=0` is the standard answer** for read-only Trino federation.

### Alternative: PostgreSQL role-level CONNECTION LIMIT as a simpler first guard

If you can't deploy PgBouncer yet, at minimum set:

```sql
ALTER ROLE trino_reader CONNECTION LIMIT 50;
```

This alone won't solve "too many connections" — Trino will still open 50 connections and hit the ceiling. But it prevents runaway JDBC client behavior from exhausting Postgres entirely. It's a stopgap, not a solution.

---

**Bottom line**: Use PgBouncer with transaction pooling and `prepareThreshold=0` in the JDBC URL. Layer with Postgres role-level `CONNECTION LIMIT` and Trino resource groups for a production-ready setup.
