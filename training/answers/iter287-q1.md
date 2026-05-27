# Iter287 Q1 — Postgres Column Silently Missing in Trino (Unsupported Type Handling)

## Answer

Yes — this is a known and documented behavior. Trino's PostgreSQL connector silently drops columns with types it cannot map, with no error or warning.

## The default setting causing this

The property `postgresql.unsupported-type-handling=IGNORE` is the default in `etc/catalog/app_pg.properties`. When Trino encounters a column type it doesn't know how to map, it simply removes that column from the schema entirely — it won't appear in `DESCRIBE`, `SELECT *`, or any query output. No error, no warning.

## Important clarification: custom ENUMs map natively to VARCHAR

PostgreSQL custom ENUM types (`CREATE TYPE order_status AS ENUM (...)`) map natively to Trino `VARCHAR` — no config required. If your ENUM column is disappearing, the cause is almost certainly a **different column in the same table** with a truly unsupported type (e.g., `hstore`, range types, `citext`, geometric types, composite custom types). When any one column has an unsupported type and `IGNORE` is the default, that column is silently dropped.

## How to diagnose which column is the actual problem

Enable JDBC debug logging temporarily to find the exact offending column. Add to `etc/log.properties` on the coordinator:

```properties
io.trino.plugin.jdbc=DEBUG
```

Restart the coordinator, then check `var/log/server.log` for lines like:

```
io.trino.plugin.jdbc.DefaultJdbcMetadata - Unsupported type: hstore on column orders.metadata
```

This names the culprit. Reset to `INFO` and restart after diagnosing — debug logging is very verbose.

You can also compare `DESCRIBE app_pg.public.orders` in Trino against `\d public.orders` in Postgres — any column present in Postgres but absent in Trino is being silently dropped.

## The fix: expose unsupported columns as VARCHAR strings

In `etc/catalog/app_pg.properties`:

```properties
connector.name=postgresql
connection-url=jdbc:postgresql://app-postgres-replica.app.svc.cluster.local:5432/appdb
connection-user=${ENV:APP_PG_USER}
connection-password=${ENV:APP_PG_PASSWORD}

postgresql.unsupported-type-handling=CONVERT_TO_VARCHAR
```

After restarting the coordinator and workers, the previously-missing column appears as `VARCHAR`:

```sql
SELECT order_status FROM app_pg.public.orders LIMIT 5;
-- Returns: 'pending', 'fulfilled', 'cancelled' as VARCHAR strings
```

## Session-level override (no restart needed for testing)

```sql
SET SESSION app_pg.unsupported_type_handling = 'CONVERT_TO_VARCHAR';
SELECT * FROM app_pg.public.orders;
```

Note the naming convention: catalog properties use hyphens (`unsupported-type-handling`); session properties use underscores and the catalog name prefix (`app_pg.unsupported_type_handling`).

## Summary

| Setting | Behavior |
|---|---|
| `IGNORE` (default) | Unsupported-type columns silently disappear from schema — no error |
| `CONVERT_TO_VARCHAR` | Columns appear as VARCHAR strings — values are the Postgres text representation |

For your ENUM column specifically: if it's defined as a native Postgres ENUM, it should already map to VARCHAR without any config change. Use the debug logging to confirm which column is actually triggering the drop.
