# Iter 171 Q1 — Cross-Catalog Trino Views: Accuracy and Staleness

## Answer

Your question gets at a critical architectural choice: **Trino views are stored SQL definitions that re-execute every time they're queried**, so they are always working against the current schema — but there's a metadata-caching layer in between that can cause silent errors if you're not careful. Here's the complete picture.

### (1) How Trino views work: stored SQL vs. materialized

Trino supports **two types of views**:

- **Stored views** (what `CREATE VIEW` produces): Trino stores the SQL definition only — **not the results**. Every query that touches the view re-executes the underlying SQL from scratch.

- **Materialized views**: Iceberg doesn't natively support materialized views in the same way traditional data warehouses do. If you need materialized semantics, you'd build a separate Iceberg table with periodic refresh jobs.

**For your cross-catalog join (Iceberg events + Postgres accounts)**, a stored view is the right choice:

```sql
CREATE VIEW analytics.events_with_accounts AS
SELECT 
  e.event_id,
  e.event_time,
  e.user_id,
  a.account_name,
  a.plan
FROM iceberg.analytics.events e
JOIN app_pg.public.accounts a ON e.user_id = a.account_id
WHERE e.event_time > CURRENT_TIMESTAMP - INTERVAL '90' DAY;
```

Every time an analyst queries this view, Trino executes the entire definition fresh: scans both catalogs, runs the join, applies the WHERE clause. **The view picks up changes to the underlying table structures** — but only if metadata caching doesn't get in the way.

### (2) Schema changes, metadata cache, and how the interaction breaks

**The danger is NOT in the view definition itself — it's in the metadata cache in front of the Postgres connector.**

The **metadata cache properties** (set in `etc/catalog/app_pg.properties`) are:

```properties
# How long Trino caches schema metadata (table list, column list, column types) from Postgres.
# Default: 0s (caching disabled)
# Common production values: 60s to 300s
metadata.cache-ttl=60s

# Also cache "table not found" responses for the same TTL
metadata.cache-missing=true
```

**The default is `0s` (caching OFF)**, so if you haven't explicitly enabled caching, schema changes are visible immediately. **But if someone set `metadata.cache-ttl=60s` for performance**, then:

- A new column added to Postgres is **invisible to Trino for up to 60 seconds**.
- If your view tries to `SELECT` that new column within those 60 seconds, the query fails with `column not found` — not silent, but an error.
- If your view doesn't reference the new column by name, it continues working — the view still works, just can't reach the new data.
- Once the cache expires (or is manually flushed), the next query sees the new schema.

### (3) How to refresh metadata manually

**Never wait for the cache to expire.** Use the `flush_metadata_cache()` procedure to invalidate the cache on demand:

```sql
-- Flush ALL metadata for the Postgres catalog (immediate, no pod restart)
CALL app_pg.system.flush_metadata_cache();

-- Or flush just one table (more surgical)
CALL app_pg.system.flush_metadata_cache(
    schema_name => 'public',
    table_name  => 'accounts'
);
```

This works on-the-fly with no pod restart and is cluster-wide (run it once on any coordinator; all workers see the result).

**Checklist when a Postgres schema change breaks your view:**

1. Check the metadata cache setting in `etc/catalog/app_pg.properties`. If `metadata.cache-ttl` is `0s` or absent, caching is OFF.
2. If `metadata.cache-ttl > 0`: run `CALL app_pg.system.flush_metadata_cache();`
3. Update the view definition if the change affects column names the view explicitly references.
4. Verify with `DESCRIBE app_pg.public.accounts;` — you should see the new column immediately after the flush.

### (4) The silent data corruption risk

This is real, but only manifests under specific conditions.

**Scenario where silent corruption happens:**

1. **Metadata cache is enabled** (`metadata.cache-ttl=60s`).
2. **A column is RENAMED** on Postgres (e.g., `plan_type` → `plan_tier`).
3. **Your view explicitly references the old column name**: `SELECT ... a.plan_type ... FROM accounts a`.
4. **Within the cache window**: Trino's cached schema still lists `plan_type` as a real column. The planner accepts the query as valid and pushes it to Postgres.
5. **Postgres rejects the query** because `plan_type` no longer exists — but in some pipelines, the error may be swallowed and result in NULLs.

**The bigger silent risk — column-level data mismatch:**

- Postgres has 10 columns. Your view is `SELECT * FROM accounts` with no explicit column list.
- A new column `col11` is added to Postgres.
- The metadata cache says the table has 10 columns (stale).
- Trino's planner projects only 10 columns when it constructs the JDBC query.
- Downstream aggregations assume `col11` is there and treat it as NULL — **silent mismatch** with no error thrown.

### (5) Concrete recommendations

**For the Postgres catalog configuration** (`etc/catalog/app_pg.properties`):
```properties
# CRITICAL: for cross-catalog joins with Iceberg, keep metadata cache disabled
# unless you have specific latency problems. Default (0s) is the safest.
metadata.cache-ttl=0s
metadata.cache-missing=true
```

**Use explicit column lists in your view** (never `SELECT *`):
```sql
CREATE VIEW analytics.events_with_accounts AS
SELECT 
  e.event_id,
  e.event_time,
  e.user_id,
  a.account_id,
  a.account_name,
  a.plan,
  a.status
FROM iceberg.analytics.events e
JOIN app_pg.public.accounts a ON e.user_id = a.account_id;
```

**When a Postgres schema change happens:**

1. Run the change on Postgres (DBA side).
2. Immediately flush Trino's cache: `CALL app_pg.system.flush_metadata_cache();`
3. If the change affects the view (column rename, type change): update the view definition with `CREATE OR REPLACE VIEW`.
4. Test the updated view: `SELECT * FROM analytics.events_with_accounts LIMIT 10;`

**The bottom line:** Trino views stay accurate because the view definition re-executes on every query against the current schema. The risk is not in the view itself, but in the metadata cache of the Postgres connector. Keep the cache OFF (the default), flush it manually when needed, use explicit column lists, and monitor join results for anomalies.
