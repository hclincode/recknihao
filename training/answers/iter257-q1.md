# Iter257 Q1 — Trino Metadata Caching for Postgres Tables

## Answer

Yes, Trino is "remembering" something about your Postgres tables between queries — but the full story is more subtle than you might expect, and it depends on how your catalog is configured.

### What Trino Actually Caches: Metadata, Not Data

When Trino queries a Postgres table, it needs to know three things before it can plan the query: (1) the table exists, (2) what columns it has, and (3) their data types. This information — called **metadata** — is what Trino caches, not the actual rows of data. Think of it like learning the blueprint of a house once instead of checking the blueprint every time you visit.

### The Default: Caching Is OFF (metadata.cache-ttl=0s)

Out of the box, OSS Trino has **caching disabled** for PostgreSQL metadata. The property `metadata.cache-ttl` defaults to `0s`, which means "always ask Postgres for fresh schema information on every single query." So if caching is off by default, why is your second query faster?

**The most likely explanation:** Even though Trino doesn't cache metadata, the **JDBC driver and your operating system do**. The JDBC connection to Postgres reuses a network socket between queries, and the OS likely has the Postgres replica's IP in its DNS cache and TCP connection state. The first query pays the cost of these lower-level setup steps; the second query reuses those connections. This is not Trino caching — it's connection reuse and OS-level networking optimizations.

### If You've Enabled Metadata Caching: Here's How It Works

If your Trino catalog has `metadata.cache-ttl` set to a non-zero value, then yes, Trino is actively caching Postgres metadata.

**How to check your config:**

Look at `etc/catalog/app_pg.properties` (or whatever your Postgres catalog is named). If you see:
```properties
metadata.cache-ttl=60s
metadata.cache-missing=true
```
Then metadata caching is enabled.

**What metadata.cache-ttl does:**
- `metadata.cache-ttl=0s` (default) — Every query fetches fresh table names, column names, and column types from Postgres. No caching at all.
- `metadata.cache-ttl=60s` — Trino remembers the schema of each table for 60 seconds. Within that 60-second window, identical queries see the same column list without re-querying Postgres. After 60 seconds, the cached entry expires and Trino fetches fresh metadata.

**metadata.cache-missing=true** (default `false`) is a companion property. By default, Trino also re-checks when you query a table that doesn't exist — even with caching enabled. Setting `metadata.cache-missing=true` also caches "table not found" responses for the same TTL, reducing unnecessary round-trips to Postgres.

### The Trade-off: Speed vs. Schema Evolution

| `metadata.cache-ttl` value | Pro | Con |
|---|---|---|
| `0s` (default) | Always up-to-date; no refresh ever needed | Every query asks Postgres for metadata; adds load on read replica at high query volume |
| `60s`–`300s` (typical prod) | Drastically reduces metadata queries; speeds up query planning for repeated queries | **After you change the Postgres schema, Trino serves stale metadata for up to the TTL duration** |

### What Happens When You Change the Postgres Schema

If `metadata.cache-ttl=0s` (default), schema changes appear in Trino on the **very next query** — no action needed.

If `metadata.cache-ttl=60s` and you rename a column, add a column, or drop a column on Postgres:
- Trino continues serving the old schema for up to 60 seconds.
- Queries referencing a newly renamed column will fail with "column not found."
- Queries referencing a dropped column will send the old name to Postgres, which rejects it.
- Views with `SELECT *` silently omit new columns until the cache expires or you manually flush.

### How to Force-Refresh the Cache Immediately

You do NOT need to wait for the TTL to expire or restart Trino. There's a system procedure to flush the metadata cache on demand:

```sql
CALL app_pg.system.flush_metadata_cache();
```

Replace `app_pg` with your actual catalog name. This procedure:
- Invalidates the entire metadata cache for that catalog immediately.
- Works across all Trino workers in your cluster — run it once from any Trino client.
- Does not require a restart.

**Example runbook after a Postgres schema change:**
```sql
-- 1. Postgres team runs:
-- ALTER TABLE accounts ADD COLUMN region VARCHAR(64);

-- 2. From any Trino client, flush immediately (don't wait for TTL):
CALL app_pg.system.flush_metadata_cache();

-- 3. Verify the new column is visible:
DESCRIBE app_pg.public.accounts;
-- Should show 'region' in the column list now.
```

### When to Enable Metadata Caching (and When NOT To)

**Enable `metadata.cache-ttl=60s` if:**
- Your Postgres schema is stable and rarely changes.
- Your analytics queries are repetitive (lots of queries hitting the same tables).
- You want to reduce load on your Postgres read replica.
- You have a runbook ready to flush the cache after DDL changes.

**Leave `metadata.cache-ttl=0s` if:**
- Your Postgres schema is under active evolution (frequent migrations, column renames).
- Query volume is low enough that metadata queries don't add noticeable load.
- You want zero risk of serving stale schema info.

### Summary

The performance difference you're seeing is most likely **not Trino's metadata cache** (which is off by default). It's lower-level networking setup — the JDBC driver opening a fresh TCP connection, OS DNS resolution, connection warmup. The second query reuses these connections and runs faster. This is normal and expected.

If you're running high query volume and want to reduce Postgres load further, set `metadata.cache-ttl=60s` in your catalog properties file. But remember: **run `CALL app_pg.system.flush_metadata_cache();` after any Postgres schema changes**, or wait up to 60 seconds for the cache to auto-expire.
