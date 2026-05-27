# Iter280 Q2 — Postgres Schema Cache: flush_metadata_cache() for New Columns

## Answer

Yes — Trino caches the Postgres table structure (column list, types) to reduce repeated round-trips. When you add a column via `ALTER TABLE ... ADD COLUMN`, the cache doesn't auto-expire. Here's how to flush it without restarting the cluster.

### 1. Trino Caches Postgres Schema Metadata

The PostgreSQL connector caches schema metadata (column names, types) according to the `metadata.cache-ttl` property in your catalog config. The default is `0s` (caching disabled), but many production setups enable it to reduce planning overhead:

```properties
# etc/catalog/app_pg.properties
metadata.cache-ttl=60s    # or 300s, or whatever your setup uses
```

When you add a column to Postgres, Trino's cache still holds the old schema until the TTL expires. The new column is invisible to Trino queries until that happens.

### 2. flush_metadata_cache() for Postgres — It DOES Exist

Unlike the Iceberg connector (which has NO flush procedure), **the PostgreSQL connector exposes a metadata cache flush command**:

```sql
CALL app_pg.system.flush_metadata_cache();
```

Replace `app_pg` with your Postgres catalog name. This invalidates the cached schema immediately. The next query to Postgres re-fetches fresh schema including your new column — no restart required.

You can also scope it to a specific schema or table with optional parameters:
```sql
CALL app_pg.system.flush_metadata_cache(
  schema_name => 'public',
  table_name => 'users'
);
```

**Scope:** The metadata cache lives on the **coordinator only** — workers do not cache Postgres schema metadata. Flushing the coordinator is sufficient for your entire cluster.

### 3. The SELECT * View Freeze Problem

If you have Trino views using `SELECT *` that reference this Postgres table, flushing the metadata cache **does NOT fix those views**. Here's why:

When a view is created, Trino expands `SELECT *` to an explicit frozen column list stored in the metastore. Adding a Postgres column makes it invisible through the view — the view still projects only the columns that existed at creation time.

To update the view, re-create it:
```sql
CREATE OR REPLACE VIEW analytics.your_view_name AS
SELECT * FROM app_pg.public.users;
```

This re-expands the column list. Direct table queries are fixed by `flush_metadata_cache()` alone; views require this additional step.

### 4. For Frequent Schema Changes — Lower the TTL

If your team adds columns often, lower the TTL or disable caching:

```properties
metadata.cache-ttl=0s    # disable caching — every query re-fetches schema
# or
metadata.cache-ttl=10s   # short TTL — schema changes visible within 10 seconds
```

The tradeoff: more round-trips to Postgres for schema lookups, but schema changes are visible immediately.

TTL changes require a coordinator restart to take effect (catalog property reload in static mode).

### Summary

| Problem | Fix |
|---|---|
| New Postgres column invisible in Trino | `CALL app_pg.system.flush_metadata_cache();` |
| Column visible in table query but not in a Trino view | `CREATE OR REPLACE VIEW ...` to unfreeze SELECT * |
| Happens too often | Lower `metadata.cache-ttl` in catalog properties |
| Need a cluster-wide flush | Only coordinator has the cache — flushing coordinator is sufficient |

The key distinction: the **Postgres** connector's `flush_metadata_cache()` exists and works. The **Iceberg** connector does NOT have this procedure — those are two separate caches with different remediation paths.
