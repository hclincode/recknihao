# Iter 233 Q2 — MySQL Metadata Caching in Trino (metadata.cache-ttl)

## Answer

Yes, that's expected behavior — and it's easily fixed.

Here's what's happening: Trino is **fetching table and column metadata from your MySQL replica during query planning**. This includes the table schema, column names, column types, and related system information. Trino does this **before** executing the actual query so it can optimize what to ask MySQL for.

By default, **metadata caching is turned OFF in the Trino MySQL connector** (`metadata.cache-ttl=0s`). That means on every single query, Trino makes fresh catalog calls to MySQL. At even modest query volume, this adds up to unnecessary load on your replica.

### The fix: Enable schema metadata caching with `metadata.cache-ttl`

Edit your MySQL catalog file (`etc/catalog/billing_mysql.properties`):

```properties
metadata.cache-ttl=30s
metadata.cache-missing=true
```

**What this does:**
- `metadata.cache-ttl=30s` — Trino caches the table schema (columns, types, table list) for 30 seconds in memory. Within that window, it doesn't ask MySQL again. At high query volume, this drastically cuts replica load.
- `metadata.cache-missing=true` — Also cache "table not found" responses, so queries on non-existent tables don't round-trip to MySQL either.

**Recommended values:** `30s`–`60s` for MySQL to balance caching benefit against schema freshness.

### Trade-off to understand

- **Pro**: Reduced metadata query load on your replica; faster query planning when many queries hit the same tables.
- **Con**: If someone runs a DDL change on MySQL (like `ALTER TABLE ... RENAME COLUMN`), Trino will keep seeing the old schema for up to 30 seconds. To pick up the change immediately, flush the cache manually:

```sql
CALL billing_mysql.system.flush_metadata_cache();
```

Note: the MySQL connector's `flush_metadata_cache()` takes **no parameters** — unlike the Hive/Delta connectors which have named parameters like `schema_name`/`table_name`. If you add those parameters on MySQL, you'll get an error.

For a stable SaaS schema with infrequent migrations, this trade-off is worth it. If schema changes happen constantly, keep `metadata.cache-ttl=0s` and accept the metadata query overhead.

### Important: Reloading the catalog

Changing the TTL requires reloading the catalog. You'll need a Trino restart or a hot-reload mechanism your deployment supports. Once reloaded, the new TTL takes effect immediately for the next query.
