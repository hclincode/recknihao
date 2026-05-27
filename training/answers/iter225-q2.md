# Iter 225 Q2 — MySQL Schema Change Not Visible in Trino: Metadata Cache and Flush

## Answer

Yes, Trino can cache schema metadata from MySQL — but whether it's actually happening depends on how your catalog is configured. Here's what's going on and how to fix it immediately.

### Does the MySQL Connector Cache Metadata?

Yes. The MySQL connector has two configuration options controlling schema caching:

**`metadata.cache-ttl`** (default: `0s`) — How long Trino caches table schemas, column names, and types from MySQL. If set to `0s` (the default), caching is OFF — Trino fetches fresh schema on every query. If set to any value like `60s` or `300s`, Trino caches that metadata for that duration.

**`metadata.cache-missing`** (default: `false`) — Whether to also cache negative responses ("table not found"). Less relevant for your case.

### Why Is Trino Still Showing the Old Column Name?

If MySQL shows the new column name on direct connection, then either:

1. **Your catalog has `metadata.cache-ttl` set to a non-zero value** — Trino cached the old schema and is serving it until the TTL expires. This is the most common cause.

2. **A Trino view was created with the old column name** — Trino views freeze their column list at `CREATE VIEW` time. If someone created a view referencing the old column, you'd need to `CREATE OR REPLACE VIEW` to pick up the change. This is separate from the metadata cache.

### How to Check If Caching Is Enabled

Look at your MySQL catalog properties file (typically `etc/catalog/billing_mysql.properties`):

```properties
# etc/catalog/billing_mysql.properties
metadata.cache-ttl=60s   # Caching ON — old schema cached for 60 seconds
```

If the line is absent or set to `0s`, caching is off.

### How to Flush the Cache Immediately

You don't need to restart anything. Run this from any Trino client:

```sql
CALL billing_mysql.system.flush_metadata_cache();
```

That's a parameterless call — no `schema_name`, no `table_name`, no `older_than`. The MySQL connector's `flush_metadata_cache()` takes no parameters and invalidates the entire catalog cache cluster-wide. Run it once; every Trino worker picks up the freshly fetched schema on the next query.

**CRITICAL:** Do NOT pass named parameters like `schema_name => 'app'` or `table_name => 'invoices'`. Those exist only on the Hive and Delta Lake connectors, not on MySQL or PostgreSQL JDBC connectors. That syntax fails with "Procedure not registered." Keep it parameterless for MySQL.

### Alternative: Wait for TTL to Expire

If your catalog has `metadata.cache-ttl=60s`, the cache entry expires in 60 seconds and the next query picks up the new schema. Flushing is better because it's immediate, but waiting works if you can tolerate the delay.

### What If `metadata.cache-ttl` Is `0s` (Caching Is Off)?

If caching is off, Trino should have picked up the new column name immediately. If it's still showing the old name with cache disabled, the issue is likely:
- A Trino view that was created with the old column name in its frozen column list. Run `CREATE OR REPLACE VIEW` with an explicit, updated column list.
- You're referencing the old column name in your query SQL. Once you flush or the TTL expires, queries using the NEW column name will work correctly.

### Best Practice Going Forward

For a stable MySQL schema with infrequent migrations (typical SaaS setup), set:
```properties
metadata.cache-ttl=60s
metadata.cache-missing=true
```

This reduces metadata-fetch load on your MySQL replica during query planning at high concurrency. Then adopt the habit: **anytime someone runs a schema change on MySQL, immediately run `CALL billing_mysql.system.flush_metadata_cache();` in Trino** to invalidate the stale cache.

For a MySQL database under active, continuous schema evolution, leave `metadata.cache-ttl=0s` and accept the small metadata-query overhead — freshness is more important than reducing replica load in that case.
