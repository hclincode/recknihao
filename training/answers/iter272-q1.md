# Iter272 Q1 — Trino PostgreSQL Metadata Caching: Why New Columns Disappear and How to Fix It

## Answer

Yes, Trino is almost certainly caching your table structure. Here's what's happening, how to fix it right now, and how to prevent it from recurring.

### The Root Cause: Metadata Caching

When you add a column to a Postgres table, Trino's PostgreSQL connector maintains an in-memory cache of table schemas. If your cluster has `metadata.cache-ttl` set to anything other than `0s`, Trino serves stale schema information for up to that TTL duration.

Timeline of what happened:
1. You ran `ALTER TABLE accounts ADD COLUMN new_feature_flag BOOLEAN;` in Postgres.
2. The column exists in Postgres immediately — `psql` can see it.
3. Trino's metadata cache still holds the **old** column list.
4. Trino's query planner checks the cache, doesn't find `new_feature_flag`, and returns "column not found."

### Immediate Fix: Flush the Metadata Cache

```sql
CALL app_pg.system.flush_metadata_cache();
```

Replace `app_pg` with your actual PostgreSQL catalog name. This invalidates Trino's in-memory schema cache **immediately and cluster-wide** — no restart needed. Your new column will appear on the very next query.

### Two Failure Modes to Know

**Mode 1: Hard error (what you're seeing)**

```sql
-- Postgres has: id, name, created_at, new_feature_flag
-- Trino cache hasn't refreshed yet

SELECT id, name, created_at, new_feature_flag FROM app_pg.public.accounts;
-- Error: Column 'new_feature_flag' cannot be resolved
```

Fix: `CALL app_pg.system.flush_metadata_cache();` and retry.

**Mode 2: Silent data loss (worse — no error)**

If a Trino view was defined with `SELECT *`, new columns become invisible after a schema change — no error, query succeeds, but data is missing:

```sql
-- View created before new column existed (SELECT * frozen at creation time)
CREATE VIEW analytics.accounts_view AS
SELECT * FROM app_pg.public.accounts;

-- After Postgres adds new_feature_flag: Trino still expands SELECT * to the OLD column list
SELECT * FROM analytics.accounts_view;
-- Returns rows successfully, but new_feature_flag is silently missing
```

**Prevention**: Always use explicit column lists in view definitions, never `SELECT *`. Update existing views after schema changes with `CREATE OR REPLACE VIEW`:

```sql
-- Rewrites the frozen column list atomically; preserves all existing grants
CREATE OR REPLACE VIEW analytics.accounts_view AS
SELECT id, name, created_at, new_feature_flag FROM app_pg.public.accounts;
```

### Check Your Cache Configuration

Look in `etc/catalog/app_pg.properties`:

```properties
# Caching OFF — schema fetched fresh on every query
metadata.cache-ttl=0s

# Caching ON — stale schema for up to 300 seconds
metadata.cache-ttl=300s
```

| Setting | Pros | Cons |
|---|---|---|
| `0s` (off) | New schema appears immediately after Postgres DDL | Every query issues metadata lookups to Postgres |
| `60s`–`300s` (on) | Reduces metadata query load; faster query planning | Must flush cache after every schema migration |

**Recommendation**: For a SaaS product with frequent schema migrations (weekly or more), use `metadata.cache-ttl=0s` — the operational friction of manual flushing outweighs the performance benefit. For infrequent migrations, use a short TTL with an automated flush step in your deploy pipeline.

### Operationalize It: Add Flush to Your Migration Script

Add this as the final step of every Postgres schema migration:

```sql
-- Flyway/Liquibase post-migration step
CALL app_pg.system.flush_metadata_cache();
```

Make it automatic so you never have to remember.

### Important: Changing the TTL Requires a Restart

`metadata.cache-ttl` is read when the catalog loads. Running `flush_metadata_cache()` clears cached entries but does NOT re-read the properties file — the catalog keeps using the old TTL value until you restart the Trino coordinator.

### Schema Drift Detection

Add this to your data CI/CD to catch mismatches before they hit users:

```sql
-- Compare Postgres vs Trino column counts
SELECT 'postgres' AS source, COUNT(*) AS column_count
FROM TABLE(
  app_pg.system.query(
    query => 'SELECT column_name FROM information_schema.columns
              WHERE table_schema = ''public'' AND table_name = ''accounts'''
  )
)
UNION ALL
SELECT 'trino' AS source, COUNT(*) AS column_count
FROM app_pg.information_schema.columns
WHERE table_schema = 'public' AND table_name = 'accounts';

-- If counts differ, you have schema drift
```

### TL;DR

1. **Right now**: `CALL app_pg.system.flush_metadata_cache();`
2. **Check config**: Look for `metadata.cache-ttl` in `etc/catalog/app_pg.properties`
3. **Update views**: Use `CREATE OR REPLACE VIEW` with explicit column lists, not `SELECT *`
4. **Automate**: Add the flush call as the last step of your migration script
5. **Consider**: `metadata.cache-ttl=0s` for frequently-evolving schemas
