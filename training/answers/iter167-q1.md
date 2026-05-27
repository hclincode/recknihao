# Iter 167 Q1 — Two Postgres Catalogs in Trino

## Answer

You can absolutely create two separate catalog configuration files pointing to two different Postgres hosts — and they will work independently without interfering with each other.

## The good news: separate catalogs = separate, isolated connections

Each catalog in Trino is completely independent. When you create `etc/catalog/app_pg.properties` pointing to your application database and `etc/catalog/metrics_pg.properties` pointing to your metrics database, **Trino manages them as entirely separate data sources**. Connections to one do not affect the other. You can query both in the same SQL statement without any shared resource conflicts.

## What two separate catalog files look like

**File 1: `etc/catalog/app_pg.properties`** (your main app database, read replica)
```properties
connector.name=postgresql
connection-url=jdbc:postgresql://app-postgres-replica.app.svc.cluster.local:5432/appdb?defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10
connection-user=${ENV:APP_PG_USER}
connection-password=${ENV:APP_PG_PASSWORD}
metadata.cache-ttl=60s
metadata.cache-missing=true
```

**File 2: `etc/catalog/metrics_pg.properties`** (your metrics database, also a read replica)
```properties
connector.name=postgresql
connection-url=jdbc:postgresql://metrics-postgres-replica.metrics.svc.cluster.local:5432/metricsdb?defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10
connection-user=${ENV:METRICS_PG_USER}
connection-password=${ENV:METRICS_PG_PASSWORD}
metadata.cache-ttl=60s
metadata.cache-missing=true
```

Mount both as separate ConfigMaps in your Trino coordinator and worker pods, restart the pods, and verify:

```sql
SHOW CATALOGS;  -- you should see both app_pg and metrics_pg
SHOW TABLES FROM app_pg.public;
SHOW TABLES FROM metrics_pg.public;
```

## The critical caveat: OSS Trino 467 has NO native JDBC connection pooling

**OSS Trino 467's PostgreSQL connector does not have built-in connection pooling.** Properties like `connection-pool.enabled` or `connection-pool.max-size` are **NOT in open-source Trino 467** — they are silently ignored (they belong to Starburst Enterprise).

Every concurrent Trino query that touches Postgres opens a fresh JDBC connection. With 20 Trino workers, you can easily exceed your Postgres `max_connections` limit.

**The solution is to bound connections from OUTSIDE Trino** using these three layers:

1. **PgBouncer in transaction-pooling mode** — critical: add `prepareThreshold=0` to your JDBC URLs when going through PgBouncer in transaction mode:
   ```properties
   # app_pg.properties (via PgBouncer)
   connection-url=jdbc:postgresql://pgbouncer.app.svc.cluster.local:6432/appdb?prepareThreshold=0&defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10
   
   # metrics_pg.properties (via its own PgBouncer)
   connection-url=jdbc:postgresql://pgbouncer.metrics.svc.cluster.local:6432/metricsdb?prepareThreshold=0&defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10
   ```

2. **Postgres role-level `CONNECTION LIMIT`** on each replica:
   ```sql
   ALTER ROLE trino_reader CONNECTION LIMIT 50;
   ```

3. **Trino resource groups** to cap concurrent federated queries.

Your two catalogs use separate PgBouncer instances — they don't share connection pools.

## Always use a read replica

**Never point Trino at your OLTP primary.** Point at a dedicated read replica for each Postgres database. A single analytical join can hold long-running transactions, saturate connection slots, and cause replica lag on the primary.

## Joining across both catalogs in SQL

```sql
SELECT 
  c.customer_id,
  c.company_name,
  COUNT(e.event_id) AS event_count
FROM app_pg.public.customers c
JOIN metrics_pg.public.event_counts e ON c.customer_id = e.customer_id
WHERE c.created_at > CURRENT_DATE - INTERVAL '30' DAY
GROUP BY c.customer_id, c.company_name;
```

Both catalogs are available in the same query — Trino fetches from each via JDBC and does the join on Trino workers.
