# Iter246 Q1 — Trino Metadata Caching: Schema Evolution Without Restart

## Yes, Trino is caching your table structure — and you can force a refresh without restarting

### Why restarting fixed it

Trino's PostgreSQL connector has a **schema metadata cache** that stores information about table structures (column names, types, etc.). By default, this cache is **disabled** (set to 0 seconds), but if your cluster has it enabled — or if it was enabled at some point — the cache was serving you stale metadata. Restarting Trino cleared the entire cache, forcing it to re-fetch the current schema from Postgres on the next query.

### Check your cache configuration first

Look at your Trino PostgreSQL catalog configuration file (typically `etc/catalog/app_pg.properties` on your coordinator). Search for:

```
metadata.cache-ttl
```

If this line:
- **Does NOT exist or is set to `0s`**: caching is disabled. Your problem is something else — the new column should show up immediately. Double-check that the column actually exists in Postgres by connecting directly.
- **Is set to any value like `60s`, `300s`, or higher**: this is your culprit. The cache was preventing Trino from seeing the new column until that time window expired.

### The fix: flush the cache without restarting

**Do NOT restart Trino again.** Instead, use the `flush_metadata_cache()` system procedure. Connect to Trino and run:

```sql
CALL app_pg.system.flush_metadata_cache();
```

Replace `app_pg` with whatever your actual PostgreSQL catalog name is. This command:
- Invalidates the in-memory metadata cache **immediately**
- Takes effect on the very next query — no restart, no pod rolling
- Works as a hot operation; you can run it anytime

After running that, your next query will re-fetch the schema from Postgres and pick up the new column.

### The sustainable solution: understand the cache-TTL trade-off

| `metadata.cache-ttl` | After you add a column to Postgres | After you run `flush_metadata_cache()` |
|---|---|---|
| `0s` (default) | Visible on the next query automatically | Not needed — already visible |
| `60s` or higher | Hidden for up to that many seconds | Immediately visible on the next query |

**The trade-off:**
- **Cache disabled** (`0s`): always-fresh schema, but Trino hits Postgres for metadata on nearly every query. At high query volume, this adds load to your Postgres replica.
- **Cache enabled** (`60s`-`300s`): much less metadata load on Postgres, but schema changes have a visibility delay.

For a stable SaaS Postgres schema with infrequent migrations, a common production setting is:

```properties
# etc/catalog/app_pg.properties
connector.name=postgresql
connection-url=jdbc:postgresql://your-postgres-replica:5432/your_db
connection-user=${ENV:POSTGRES_USER}
connection-password=${ENV:POSTGRES_PASSWORD}

# Reduce metadata queries to Postgres; schema changes take up to 60s to appear
metadata.cache-ttl=60s

# Also cache "table not found" responses (avoids repeated failed lookups)
metadata.cache-missing=true
```

With this setup, your engineers understand: after a schema migration, either wait 60 seconds or run `CALL app_pg.system.flush_metadata_cache();` from any Trino client. No restarts needed.

### One important detail about changing the TTL itself

If you decide to change the `metadata.cache-ttl` value in the properties file, **simply running `flush_metadata_cache()` is NOT enough** — the new TTL value won't be picked up. You need a full catalog reload (restart the coordinator and workers in static catalog mode). Flushing the cache only clears what's currently cached; it doesn't re-read the properties file.

### Verify it worked

After flushing, check that Trino now sees the new column:

```sql
DESCRIBE app_pg.public.<your_table_name>;
```

The new column should appear in the output.
