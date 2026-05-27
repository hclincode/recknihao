# Iter263 Q2 — JDBC Connection Pool Sizing: How Many Connections Does Trino Open to Postgres?

## Answer

Your concern is well-founded. Here's the honest answer: **OSS Trino 467 has no built-in JDBC connection pooling for the PostgreSQL connector**, and the number of connections it opens scales with query parallelism. But there are well-tested solutions to cap it.

### How Many Connections Trino Opens per Query

Trino opens **one JDBC connection per split per table scanned**, not one per worker and not one per query overall.

For a simple federation query scanning a single non-partitioned Postgres table:
- **One split** is created for the table scan
- One worker task processes that split
- **One JDBC connection** is opened to Postgres

The formula for estimating peak connections:
```
peak_postgres_connections ≈ 
  (max_concurrent_federation_queries) × 
  (average_postgres_tables_per_query) × 
  (average_splits_per_table)
```

**In your situation**: You have 40 connections remaining (100 limit − 60 used by app). You can safely support roughly 10–20 concurrent single-table federation queries before hitting that ceiling.

### The Critical Gap: OSS Trino Has No Native Connection Pooling

This is important: OSS Trino 467's PostgreSQL connector has **no built-in connection pool**. Properties like `connection-pool.enabled` or `connection-pool.max-size` are Starburst Enterprise features — they don't exist in open-source Trino and are silently ignored if you add them to your catalog file.

### The Production Solution: PgBouncer

You must put **PgBouncer** between Trino and your Postgres replica. PgBouncer multiplexes many JDBC connections from Trino's workers into a smaller pool of actual Postgres backend connections.

**Minimal PgBouncer configuration:**

```ini
[databases]
appdb = host=app-postgres-replica.app.svc.cluster.local port=5432 dbname=appdb

[pgbouncer]
listen_port = 6432
pool_mode = transaction
max_client_conn = 1000           # client-side (Trino) connections
default_pool_size = 30           # actual backend connections to Postgres
server_idle_timeout = 600
```

Point Trino at PgBouncer, not Postgres directly:

```properties
# etc/catalog/app_pg.properties
connector.name=postgresql
connection-url=jdbc:postgresql://pgbouncer.app.svc.cluster.local:6432/appdb?prepareThreshold=0&defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10
connection-user=${ENV:APP_PG_USER}
connection-password=${ENV:APP_PG_PASSWORD}
```

**Critical**: The `prepareThreshold=0` parameter is **mandatory** when using PgBouncer in transaction-pooling mode. Without it, you will see intermittent `ERROR: prepared statement "S_x" does not exist` failures. This is because Postgres server-side prepared statements are scoped to individual connections, but PgBouncer's transaction mode reuses backend connections across clients — so the prepared statement from one JDBC connection no longer exists when a different connection is reused.

### A Four-Layer Defense (Use All of Them Together)

OSS Trino 467 requires multiple layers to reliably protect your Postgres connection limit:

| Layer | Controls | Configuration |
|---|---|---|
| **PgBouncer** | Multiplexes Trino JDBC connections into fewer backend connections | `default_pool_size=30` in `pgbouncer.ini` |
| **Postgres role limit** | Hard ceiling enforced by Postgres itself | `ALTER ROLE trino_reader CONNECTION LIMIT 30;` |
| **Trino resource groups** | Concurrent federation queries | `hardConcurrencyLimit: 10` in `resource-groups.json` |
| **statement_timeout** | Per-query runtime limit on Postgres | `ALTER ROLE trino_reader SET statement_timeout = '300000';` (5 min) |

Set PgBouncer `default_pool_size` and the Postgres role limit to the **same number** so the role limit acts as a hard stop if anything bypasses PgBouncer. Resource groups limit concurrent queries from the Trino side, which reduces connection pressure upstream.

### Your Specific Situation (100 connections, 60 used by app)

1. Deploy PgBouncer with `default_pool_size=30` (leaving 10 connections as headroom)
2. `ALTER ROLE trino_reader CONNECTION LIMIT 30` on Postgres
3. Configure Trino resource groups with `hardConcurrencyLimit=10` for federation queries
4. `ALTER ROLE trino_reader SET statement_timeout = '300000'` (5-minute per-query limit)

This guarantees Trino will never consume more than 30 connections from your Postgres, keeping your app's 60 connections safe.

### Summary

- Trino opens ~1 JDBC connection per split per scanned table (not 1 per worker)
- OSS Trino has **no built-in connection pool** for Postgres — this is a known gap
- The production fix is PgBouncer as an intermediary with `pool_mode=transaction` and `prepareThreshold=0` in the JDBC URL
- Layer PgBouncer `default_pool_size` + Postgres `CONNECTION LIMIT` + Trino resource group `hardConcurrencyLimit` for defense-in-depth
