# Iter 165 Q2 — Postgres Column Rename Breaking Trino Queries

## Answer

Based on the resources available, the Trino PostgreSQL connector is designed to fetch fresh metadata at the start of each query via JDBC — it does not cache Postgres table schemas the way Iceberg catalogs cache metadata files. This means a column rename in Postgres should be visible to new Trino queries immediately. Here's why your situation is inconsistent and what to do.

## Why some queries work and others fail

The inconsistency is almost certainly because the renamed column only appears in **specific queries**. Queries that reference the old column name in their SELECT or WHERE clause fail with "column not found." Queries that don't reference that column by name still work fine. It has nothing to do with caching — Trino is seeing the new Postgres schema correctly; the problem is your query SQL still uses the old column name.

## The fix: update your Trino queries to use the new column name

Since the Trino PostgreSQL connector reads schema directly from Postgres via JDBC at query-plan time, you don't need to restart Trino or invalidate any cache. Simply update the queries (and any Trino views over the Postgres table) to use the new column name.

If you have **Trino views** that reference the old column:

```sql
-- Recreate the view with the new column name
CREATE OR REPLACE VIEW myview AS
SELECT 
  e.event_id,
  a.new_column_name  -- was a.old_column_name
FROM iceberg.analytics.events e
JOIN app_pg.public.accounts a ON e.account_id = a.id;
```

## How to handle Postgres migrations cleanly going forward

1. **Search for all Trino SQL that references the renamed column** before you rename it in Postgres. Check:
   - Saved queries in your BI tools (Metabase, Superset, etc.)
   - Trino views (`SELECT * FROM information_schema.views WHERE view_definition LIKE '%old_column_name%'`)
   - Application code that sends SQL to Trino directly

2. **Rename in Postgres and update Trino queries atomically** — treat the Postgres migration and the Trino query update as a single coordinated change, not two separate steps.

3. **Use aliasing during transition** — if you can't update all downstream queries at once, you can temporarily add a computed column in Postgres that aliases the new name back to the old:
   ```sql
   -- On the Postgres side (temporary compatibility shim)
   ALTER TABLE accounts ADD COLUMN old_column_name TEXT GENERATED ALWAYS AS (new_column_name) STORED;
   -- Then update Trino queries to use new name, then drop the computed column
   ```

4. **Avoid naming columns in SELECT \*** — if your Trino queries use `SELECT *` against Postgres tables, a column rename doesn't break the query but may silently change the schema seen by downstream consumers. Be explicit about column names.

## On read replicas and statement_timeout

The federation guide recommends always pointing Trino at a dedicated read replica (never the OLTP primary). Coordinate your schema changes carefully: if you rename a column on the primary and replication is slightly lagged, the read replica Trino points at may briefly show the old schema. Check replication lag before assuming a migration is visible:

```sql
-- On the Postgres read replica
SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;
```

## What the resources don't cover

The resources don't document a `REFRESH SCHEMA` or catalog cache invalidation command for the Postgres connector — because there isn't one needed. The connector always reads schema fresh from Postgres via JDBC. If you're still seeing "column not found" errors after updating your queries to use the new column name, confirm the rename is actually on the read replica Trino is pointing at (check replication lag), and that the user Trino connects as (`trino_reader`) has `SELECT` grants on the table post-rename.
