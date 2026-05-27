# Iter 190 Q2 — Metadata Cache Invalidation: New Postgres Column Not Visible in Trino

## Answer

## Your "New Postgres Column Not Visible in Trino" Diagnosis + Fix

The 30-minute wait not working is a critical clue. Here's the full runbook.

### 1. How Trino Caches PostgreSQL Schema Metadata

Trino's PostgreSQL connector has **two catalog properties** that control metadata caching in `/etc/catalog/app_pg.properties` (or whatever you named your Postgres catalog):

```properties
metadata.cache-ttl=60s                    # How long metadata stays cached (default: 0s = OFF)
metadata.cache-missing=true               # Also cache "table not found" responses
```

- **Default (`0s`)**: Caching is OFF. Every Trino query asks Postgres for fresh column lists. No cache invalidation ever needed, but adds metadata-query load to your read replica at high query volume.
- **Production typical (`60s`–`300s`)**: Schema metadata stays cached for that duration. This speeds up repeated queries against the same tables but creates the "new columns invisible" problem you're hitting.

**Your 30-minute wait didn't work because:** If `metadata.cache-ttl` is set to anything > 0 (say, 60 seconds), Trino only refreshes the column list when the TTL expires. Waiting 30 minutes works if you wait *longer* than the TTL, but that's not a reliable solution.

### 2. Direct Table Query vs. View Query (Two Different Behaviors)

This is the trap:

| Query type | After `ADD COLUMN` to Postgres | Behavior |
|---|---|---|
| **Direct table query** (`SELECT * FROM app_pg.public.accounts`) | Trino sees new column immediately when cache expires or you flush | Fresh metadata on next query |
| **SELECT * view** (`CREATE VIEW v AS SELECT * FROM app_pg.public.accounts`) | **New column is INVISIBLE even after cache flush** | Views store a *frozen* column list at creation time |

**Why?** Trino views store two things when created: the SQL text AND a resolved column schema (the explicit column list that `SELECT *` was expanded to). This list is **frozen forever**. Flushing the metadata cache makes Trino re-read Postgres's schema for direct table queries, but **does NOT update a view's frozen column list**.

### 3. The `CALL system.flush_metadata_cache()` Syntax — Parameterless on PostgreSQL

**CRITICAL:** The PostgreSQL connector's `flush_metadata_cache` procedure takes **zero parameters**. Named parameters like `schema_name => 'public'` **do NOT work on PostgreSQL** (they only work on Hive and Delta Lake connectors).

```sql
-- CORRECT for PostgreSQL connector:
CALL app_pg.system.flush_metadata_cache();

-- WRONG — will fail with "Procedure should only be invoked with named arguments":
CALL app_pg.system.flush_metadata_cache(schema_name => 'public', table_name => 'accounts');
```

**What does it do?** It **invalidates the entire catalog's metadata cache cluster-wide** immediately. No pod restart required. The next query against any table in that catalog reads fresh metadata from Postgres. That's it — it flushes the whole catalog, not individual tables.

**One optional ergonomic step** — if you want to narrow session scope:

```sql
USE app_pg.public;
CALL system.flush_metadata_cache();
```

The `USE` doesn't limit what the flush clears (it still clears the whole catalog), but subsequent unqualified table references resolve to that schema.

### 4. Why 30 Minutes Still Didn't Show New Columns — The Silent Corruption Case

Your scenario (adding two columns) matches the **"Mode 1: Silent Corruption"** failure case:

**The setup:**
- You have a Trino view defined as `CREATE VIEW analytics.foo AS SELECT * FROM app_pg.public.sometable;`
- Trino's cache currently holds the OLD column list (say, 10 columns).
- You add two new columns to the Postgres table.
- Trino's cache still says 10 columns. Trino's planner expands `SELECT *` to the cached 10-column list.

**What happens:**
- Trino queries Postgres: `SELECT col1, col2, ..., col10 FROM sometable` (the new columns are NOT in the SELECT list).
- Postgres returns those 10 columns. **No error. No warning. The new columns are invisible.**
- Downstream consumers see the old shape and never realize data is missing.

**Why the 30-minute wait didn't work:** If your `metadata.cache-ttl` is 60 seconds, waiting 30 minutes should be enough... *unless* a new query against that view re-cached it after you waited. Or you were querying a view, not the table directly. **This mode is truly silent** — no error tells you the cache is stale.

### 5. Full Diagnosis + Fix Runbook

**Step 1: Check your metadata caching setup**

```properties
# In etc/catalog/app_pg.properties, find these lines:
metadata.cache-ttl=60s           # If absent or 0s, caching is OFF
metadata.cache-missing=true
```

If `metadata.cache-ttl` is absent or `0s`, schema caching is OFF and your problem is not a stale cache — check that the new columns actually exist in Postgres and that your `SELECT` statement syntax is correct.

If `metadata.cache-ttl > 0`, proceed to Step 2.

**Step 2: Flush the metadata cache immediately**

```sql
-- Run this from any Trino client connected to any coordinator
CALL app_pg.system.flush_metadata_cache();

-- Verify the flush took effect:
SHOW COLUMNS FROM app_pg.public.<table_name>;
-- The new columns should now appear.
```

If `SHOW COLUMNS` still shows the old schema after the flush, the flush did not execute on the coordinator your client connected to — re-run the flush and verify connectivity to the right coordinator.

**Step 3: Fix any affected views**

Direct table queries are now fixed. But **if you have Trino views referencing this table, they still have the old frozen column list.**

```sql
-- Find affected views in your Trino-native catalogs (NOT the app_pg JDBC catalog):
SELECT table_catalog, table_schema, table_name, view_definition
FROM analytics.information_schema.views
WHERE view_definition LIKE '%<table_name>%';
-- Repeat for every Trino-native catalog (iceberg, hive, etc.)
```

For each view found, rewrite it with an **explicit column list**:

```sql
-- BEFORE: CREATE VIEW analytics.foo AS SELECT * FROM app_pg.public.sometable;
-- AFTER:
CREATE OR REPLACE VIEW analytics.foo AS
SELECT
  col1, col2, col3, ..., col10,   -- old columns
  new_col1, new_col2              -- new columns
FROM app_pg.public.sometable;
```

**Why explicit columns?** They make the contract visible in code, prevent future ADD COLUMN events from silently disappearing, and let code review catch schema-evolution mistakes.

**Step 4: Choose a SECURITY mode for the view (optional, but recommended)**

```sql
CREATE OR REPLACE VIEW analytics.foo
SECURITY INVOKER  -- or SECURITY DEFINER (the default)
AS SELECT ... FROM app_pg.public.sometable;
```

- `SECURITY DEFINER` (Trino's default) — the view owner's grants are used to read the base tables. Callers only need `SELECT` on the view.
- `SECURITY INVOKER` — the caller's grants are used. They must have direct access to base tables (Postgres + Iceberg).

For federated views joining Postgres + Iceberg, use `INVOKER` when analysts have base-table grants and you want Postgres row-level security (via OPA or Postgres native grants) to apply.

### 6. Prevention Going Forward

**For a stable SaaS Postgres schema with infrequent DDL:**

```properties
# In etc/catalog/app_pg.properties
metadata.cache-ttl=60s
metadata.cache-missing=true
```

This is the standard production setting. Schema changes require a manual `flush_metadata_cache()` call, but metadata-query load on the replica is drastically lower.

**For a Postgres database under active schema evolution (frequent migrations):**

```properties
metadata.cache-ttl=0s
```

Caching is off. New columns are always visible immediately. You accept the extra metadata-query load on the replica — it's the trade-off for schema evolution safety.
