# Iter265 Q2 — New Postgres Column Not Showing in Trino: Metadata Cache and View Behavior

## Answer

Your issue is likely one of two things: Trino is caching the schema from Postgres and hasn't refreshed it, or your view's column list is frozen from when it was created. Let me walk through both.

### Does Trino Cache the Schema?

Trino's PostgreSQL connector does have a metadata cache — it can cache table schemas, column lists, and column types from Postgres. However, **the cache is disabled by default** (`metadata.cache-ttl=0s`).

Check your Trino catalog configuration file (e.g., `etc/catalog/app_pg.properties`). Look for `metadata.cache-ttl`:

- **Not set or `0s`**: caching is disabled — Trino should pick up schema changes on the next query. If you're not seeing the new column with caching disabled, there may be something else going on (restart Trino, or proceed to the view step below).
- **Set to a non-zero value** (e.g., `60s`, `300s`): caching is enabled — Trino is holding the old schema in memory until the TTL expires.

### How to Force a Schema Refresh Immediately

If `metadata.cache-ttl` is non-zero, you don't have to wait for it to expire or restart Trino. Run this from any Trino client:

```sql
CALL app_pg.system.flush_metadata_cache();
```

Replace `app_pg` with whatever you named your Postgres catalog. This invalidates the entire catalog's metadata cache cluster-wide — all Trino workers get the update. The very next query will fetch fresh schema from Postgres.

After flushing, verify the new column appears:

```sql
DESCRIBE app_pg.public.your_table;
```

### The Tricky Part: Your View's Column List Is Frozen

Here's the critical behavior you need to know: **when you create a Trino view, Trino expands any `SELECT *` to an explicit column list at CREATE time and freezes it.**

So if your view was created as:

```sql
CREATE VIEW analytics.customer_view AS 
SELECT * FROM app_pg.public.customers;
```

At creation time, Trino expanded `SELECT *` to `SELECT id, name, email, created_at` (or whatever columns existed then) and stored that explicit list. **Adding a column to the Postgres table does NOT update the view's column list — even after flushing the metadata cache.**

This is why flushing the metadata cache fixes direct queries against the table, but the view still shows the old column list. The view's definition is stored separately and doesn't dynamically re-expand.

### Fixing the View

Recreate the view with `CREATE OR REPLACE VIEW`:

```sql
CREATE OR REPLACE VIEW analytics.customer_view AS
SELECT * FROM app_pg.public.customers;
```

This re-expands `SELECT *` against the current (refreshed) column list from Postgres and re-freezes it to include your new column. Existing queries to the view continue working — `CREATE OR REPLACE` is safe to run on a live view.

If your view used an explicit column list (not `SELECT *`):

```sql
-- Original view:
CREATE VIEW analytics.customer_view AS
SELECT id, name, email FROM app_pg.public.customers;

-- Update to include new column:
CREATE OR REPLACE VIEW analytics.customer_view AS
SELECT id, name, email, new_column FROM app_pg.public.customers;
```

### Your Action Checklist

1. **Check the cache setting** — open `etc/catalog/app_pg.properties`, find `metadata.cache-ttl`. Non-zero = caching is enabled.

2. **Flush the cache** (if caching is enabled):
   ```sql
   CALL app_pg.system.flush_metadata_cache();
   ```

3. **Verify direct table queries work**:
   ```sql
   DESCRIBE app_pg.public.your_table;
   -- New column should now appear
   SELECT new_column FROM app_pg.public.your_table LIMIT 5;
   ```

4. **Recreate any views** that reference the table:
   ```sql
   CREATE OR REPLACE VIEW your_schema.your_view AS
   SELECT * FROM app_pg.public.your_table;
   ```

5. **Verify the view works**:
   ```sql
   DESCRIBE your_schema.your_view;
   -- New column should now appear in the view too
   ```

### Summary

- Trino's metadata cache is disabled by default — if you're using the defaults, a Trino restart or `flush_metadata_cache()` call should fix direct table queries immediately.
- If caching is enabled (`metadata.cache-ttl` > 0), `CALL catalog.system.flush_metadata_cache()` refreshes the schema without a restart.
- Views always need to be recreated with `CREATE OR REPLACE VIEW` after schema changes — the cache flush alone does not update them.
