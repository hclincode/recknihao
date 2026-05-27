# Iter285 Q2 — Capping Concurrent Trino-to-Postgres Queries with Resource Groups

## Answer

Trino resource groups cannot route queries by data source (catalog). There's no `catalog` selector field — resource group routing happens before query parsing, so Trino doesn't yet know which connectors a query will touch. However, there are three effective controls for limiting Postgres connection load.

## What resource groups CAN and CANNOT do

Resource group selectors route queries based on: `user`, `source` (the `X-Trino-Source` HTTP header or `--source` CLI flag), `clientTags`, `queryType` (SELECT/INSERT/etc.), and `sessionPropertyFilters`. There is no `catalog` or `connector` selector.

If you want resource groups to route specific queries, engineers must tag their queries at submission time using the `source` header. A query submitted with `X-Trino-Source: federation-analytics` can be routed to a specific group; a query with no source tag cannot be distinguished from other queries.

## The three-layer approach that actually works

### Layer 1: Postgres CONNECTION LIMIT (immediate, no Trino restart)

Create a dedicated Postgres role for Trino and cap its max connections at the database level:

```sql
-- On the Postgres replica
CREATE ROLE trino_analytics WITH PASSWORD 'your_password';
ALTER ROLE trino_analytics CONNECTION LIMIT 5;
GRANT CONNECT ON DATABASE appdb TO trino_analytics;
GRANT USAGE ON SCHEMA public TO trino_analytics;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO trino_analytics;
```

Then use this role in `etc/catalog/app_pg.properties`. This takes effect immediately — no Trino restart needed. The 6th concurrent connection attempt fails fast at the Postgres socket layer rather than degrading the replica.

**Limitation**: Postgres rejects the overflow connection (no queuing). Engineers get an error instead of waiting.

### Layer 2: PgBouncer for queuing (recommended)

OSS Trino 467 has no native PostgreSQL connection pooling. The standard solution is to front your replica with PgBouncer in transaction-pooling mode:

```ini
# pgbouncer.ini
[databases]
appdb = host=app-postgres-replica.app.svc.cluster.local port=5432 dbname=appdb

[pgbouncer]
pool_mode = transaction
max_client_conn = 100        # Trino can open up to 100 connections to PgBouncer
default_pool_size = 5        # PgBouncer multiplexes to 5 actual Postgres connections
reserve_pool_size = 1
```

Update your Trino catalog to point at PgBouncer (add `prepareThreshold=0` — required for transaction-pooling mode):

```properties
# etc/catalog/app_pg.properties
connection-url=jdbc:postgresql://pgbouncer.app.svc.cluster.local:6432/appdb?prepareThreshold=0
```

Now Trino can open many connections to PgBouncer. PgBouncer queues them and drains to Postgres at 5 connections max. Engineers wait instead of getting connection errors. This requires a Trino coordinator restart to pick up the new catalog URL.

### Layer 3: Trino resource groups for cluster-wide fairness (optional)

If you want to limit total concurrent queries in the analytics group (regardless of catalog), configure resource groups. First, create the config files:

```properties
# etc/resource-groups.properties
resource-groups.configuration-manager=file
resource-groups.config-file=etc/resource-groups.json
```

```json
{
  "rootGroups": [{
    "name": "global",
    "softMemoryLimit": "80%",
    "hardConcurrencyLimit": 100,
    "maxQueued": 200,
    "subGroups": [
      {
        "name": "federation",
        "softMemoryLimit": "40%",
        "hardConcurrencyLimit": 10,
        "maxQueued": 30
      },
      {
        "name": "iceberg_only",
        "softMemoryLimit": "40%",
        "hardConcurrencyLimit": 50,
        "maxQueued": 100
      }
    ]
  }],
  "selectors": [
    {"source": ".*federation.*", "group": "global.federation"},
    {"source": ".*iceberg.*", "group": "global.iceberg_only"},
    {"group": "global"}
  ]
}
```

Engineers submitting federation queries must set the source header at query time:
```bash
# Trino CLI
trino --source=federation-analytics --execute "SELECT ..."

# JDBC (in JDBC connection URL or connection properties)
jdbc:trino://trino-coordinator:8080/app_pg?source=federation-analytics
```

**Restart requirement**: Changes to `resource-groups.json` and `resource-groups.properties` require a coordinator restart. There is no hot-reload. After updating the ConfigMap and rolling the coordinator pod, new queries use the new limits; in-flight queries continue under the old limits.

## Which approach should you use?

| Need | Approach |
|---|---|
| Hard cap on Postgres connections (no queuing) | Postgres `CONNECTION LIMIT` on the Trino role |
| Queuing overflow queries instead of failing | PgBouncer in transaction-pooling mode |
| Cluster-wide fairness across query types | Trino resource groups + source header tagging |
| Route by catalog/connector type | Not possible in Trino — use source header instead |

For your immediate problem (replica falling over), start with Layer 1 (Postgres CONNECTION LIMIT) today and Layer 2 (PgBouncer) this week. Layer 3 is optional cluster governance once the replica is stable.
