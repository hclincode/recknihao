# Iter281 Q1 — Postgres Schema Cache Flush: Exact Syntax and TTL Config

## Answer

Yes — Trino caches Postgres schema metadata. Here's the exact flush syntax and how to configure the TTL.

### Exact SQL Syntax for the Flush

For the PostgreSQL connector catalog (`app_pg`):

```sql
CALL app_pg.system.flush_metadata_cache();
```

**No parameters.** This is the critical distinction: the PostgreSQL connector (and other JDBC connectors) takes **no parameters**. The procedure immediately invalidates the coordinator's metadata cache — your new column will be visible in a `DESCRIBE` right after.

**Do NOT try** to pass `schema_name` or `table_name` as parameters — that will fail on PostgreSQL. Those named parameters only exist on the Hive and Delta Lake connectors.

```sql
-- WRONG (Delta Lake / Hive only — will error on PostgreSQL connector)
CALL app_pg.system.flush_metadata_cache(schema_name => 'public', table_name => 'users');

-- CORRECT for PostgreSQL
CALL app_pg.system.flush_metadata_cache();
```

Alternative scoped form (identical behavior — still clears entire catalog cache):
```sql
USE app_pg.public;
CALL system.flush_metadata_cache();
```

### Scope: Coordinator Only

The flush clears the coordinator's in-memory metadata cache only. Workers do not cache table metadata for the PostgreSQL connector — they receive resolved metadata from the coordinator at query time. One flush is sufficient for the entire cluster to see the new column. (Exception: HA setups with multiple coordinators behind a load balancer require flushing each coordinator separately.)

### Setting a TTL to Avoid Manual Flushes

In `etc/catalog/app_pg.properties`:
```properties
metadata.cache-ttl=60s
```

This automatically expires Postgres metadata from the cache after 60 seconds. Common production values: 60s–300s. The default is `0s` (caching disabled — every query pays a fresh `information_schema` lookup on Postgres).

For finer control:
```properties
metadata.tables.cache-ttl=60s       # table names and column lists
metadata.statistics.cache-ttl=300s  # row counts and cardinality estimates
```

**Gotcha:** Changing `metadata.cache-ttl` in the properties file and then running `flush_metadata_cache()` does NOT apply the new TTL. The flush clears cached entries but does not reload configuration — the coordinator continues using the TTL value from startup. A coordinator restart is required for TTL changes to take effect (or `DROP CATALOG` + `CREATE CATALOG` in dynamic catalog mode).

### The SELECT * View Freeze Problem

If you have Trino views using `SELECT *` on Postgres tables, adding a Postgres column does NOT automatically include it in the view. Trino freezes the column list at view-creation time. After flushing the cache, explicitly re-create any affected views:

```sql
CREATE OR REPLACE VIEW analytics.orders_view AS
SELECT id, order_date, amount, new_column   -- explicit list, not SELECT *
FROM app_pg.public.orders;
```

Direct table queries are fixed by `flush_metadata_cache()` alone. Views require this additional step.
