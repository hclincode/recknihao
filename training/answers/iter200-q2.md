# Iter 200 Q2 — JDBC Connection Model and Protecting the Postgres Replica Under Load

## Answer

The answer to your question is clearly laid out in how Trino actually opens connections, and the good news is that you have several tools to protect the replica — they just don't live where you might initially look.

---

## JDBC Connection Model: The Critical Mental Shift

First, understand how Trino opens connections to Postgres. **OSS Trino 467's PostgreSQL connector does NOT create one JDBC connection per worker.** Instead, the connector creates **one split per non-partitioned table scan**, and each split becomes one worker task, which holds exactly one JDBC connection. This means:

**For a single federation query scanning one Postgres table: you get 1 JDBC connection total, not one per worker.**

Connections scale with **concurrent queries × average Postgres tables per query × splits per table** — NOT with worker count. Worker count multiplies connections only in unusual cases:
- The query joins multiple Postgres tables (each gets its own split)
- You configure table partitioning via the `partition-column` property, so Trino opens N parallel range-scan connections
- A custom split strategy is used

For typical single-table federation, the capacity-planning formula is: `peak_connections ≈ max_concurrent_federation_queries × avg_postgres_tables_per_query`.

So if you have 20 Trino workers each running a different federation query, you'll open 20 connections (one per concurrent query), not hundreds. That's important context for sizing the defense layers below.

---

## What Happens When You Hit the Connection Limit

When Postgres's `CONNECTION LIMIT` is exceeded, Postgres rejects new connections with a hard error. This surfaces to Trino as a JDBC connection-open failure, which fails the entire query. In-flight queries continue to completion, but any new query that tries to open a connection will fail immediately. There is no graceful queueing at the database level — it's a hard rejection.

---

## The Fix: Four-Layer Defense (There Is No Trino-Side Pool)

**OSS Trino 467's PostgreSQL connector has NO native JDBC connection pool.** Properties like `connection-pool.enabled` and `connection-pool.max-size` belong to **Starburst Enterprise**, not open-source Trino. They will be silently ignored if you add them to your catalog file. Because there is no Trino-side pool, you must layer four mechanisms together:

### Layer 1: PgBouncer in Front of Postgres (The Standard Fix)

PgBouncer is a lightweight connection pooler that becomes the de-facto pool Trino lacks. Deploy it between Trino and the Postgres replica. Trino opens many short-lived connections to PgBouncer; PgBouncer multiplexes them onto a small, bounded set of real Postgres backend connections.

**Critical configuration**: Use `pool_mode = transaction` (transaction pooling). Trino's queries are read-only and don't rely on session-level state, so this mode is safe and gives the highest multiplexing factor.

**CRITICAL caveat**: When you point Trino at PgBouncer, you MUST append `prepareThreshold=0` to the JDBC URL. Without this, the PostgreSQL JDBC driver caches prepared statements (server-side) after 5 executions. PgBouncer in transaction-pooling mode may route the next transaction to a different Postgres backend that doesn't have the prepared statement — you get intermittent `ERROR: prepared statement "S_1" does not exist`. Setting `prepareThreshold=0` disables server-side prepared statements entirely.

```properties
# In etc/catalog/app_pg.properties
connection-url=jdbc:postgresql://pgbouncer.app.svc.cluster.local:6432/appdb?prepareThreshold=0&defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10
```

```ini
# pgbouncer.ini
[databases]
appdb = host=app-postgres-replica.app.svc.cluster.local port=5432 dbname=appdb

[pgbouncer]
listen_port = 6432
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 50        # at most 50 real Postgres backend connections
reserve_pool_size = 10
```

With `default_pool_size=50`, the Postgres replica sees at most 50 connections from `trino_reader` regardless of concurrent query count.

### Layer 2: Postgres Role-Level Connection Cap (Defense in Depth)

Even with PgBouncer, set a hard cap on the Postgres side:

```sql
ALTER ROLE trino_reader CONNECTION LIMIT 50;
```

If anything bypasses PgBouncer (a direct connection, a misconfiguration), Postgres rejects the 51st connection. Your application's own users (different role) are unaffected. Monitor with:

```sql
SELECT count(*) FROM pg_stat_activity WHERE usename = 'trino_reader';
```

### Layer 3: Trino Resource Groups (Concurrency Cap)

Resource groups limit how many federation queries can run concurrently. Fewer concurrent queries means fewer simultaneous Postgres connections.

Create `etc/resource-groups.json`:

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

Create `etc/resource-groups.properties`:

```properties
resource-groups.configuration-manager=file
resource-groups.config-file=etc/resource-groups.json
```

The selector matches on `source` — wire it via JDBC URL (`source=federation-queries`) or Trino CLI (`--source federation-queries`). With `hardConcurrencyLimit=10`, at most 10 federation queries run concurrently. Beyond that, queries queue (up to 100) then are rejected.

### Layer 4: Statement Timeout on the Postgres Replica

Prevent runaway queries from holding connections indefinitely:

```sql
ALTER ROLE trino_reader SET statement_timeout = '300000';  -- 5 minutes in milliseconds
```

---

## Putting It Together: A Worked Example

For your 20–30 worker cluster with a Postgres replica at `max_connections=300` and your application using ~150:

| Layer | Setting | Value |
|---|---|---|
| PgBouncer | `default_pool_size` | `50` |
| Postgres role | `CONNECTION LIMIT` | `50` |
| Trino resource group | `hardConcurrencyLimit` | `10` |
| Postgres replica | `statement_timeout` | `5min` |

This gives you a hard 50-connection ceiling from Trino's federation traffic, with at most 10 concurrent federation queries, and a 5-minute backstop on any individual query. Your application headroom: 300 - 50 = 250 connections, well above the 150 your app uses.

---

## What Actually Happens at Each Ceiling

| What hits the limit | Error behavior |
|---|---|
| PgBouncer queue full (`max_client_conn`) | Trino connection rejected; query fails with connection error |
| Postgres `CONNECTION LIMIT` (50) | `FATAL: too many connections for role "trino_reader"` — query fails |
| Resource group queue full (100 queued) | Query immediately rejected with resource-group limit error |
| Postgres `statement_timeout` (5 min) | Query killed by Postgres: `ERROR: canceling statement due to statement timeout` |

None of these are graceful, but they are bounded and predictable — and they protect your application traffic from being starved by analytics queries.
