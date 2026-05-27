# Iter 200 Q1 — Schema Evolution and Metadata Caching in Trino PostgreSQL Federation

## Answer

## Your concern is valid, and the answer depends on whether your Trino cluster has metadata caching enabled.

**Default behavior (safest for schema changes):** If your Trino cluster has `metadata.cache-ttl` set to `0s` (the default), Trino fetches the current Postgres schema on every query. A schema change — even mid-query — means Trino sees it immediately on the next query. **No cached stale schema to worry about.**

**But many production clusters turn caching ON**, and that's where your concern becomes real.

---

### When caching is enabled: two different failure modes

If someone sets `metadata.cache-ttl=60s` or `metadata.cache-ttl=300s` in your Trino PostgreSQL catalog config (to reduce load on the Postgres replica), then a schema change during this window causes one of two outcomes:

**Mode 1 — Silent corruption (the scary one)**
- **Scenario:** Someone adds a new column to your Postgres table while a Trino view uses `SELECT *`.
- **What happens:** Trino's stale cache doesn't know about the new column. The `SELECT *` in the view expands to only the old 5 columns. Trino and Postgres exchange data successfully. No errors, no warnings, no log entries. The new column is just... silently invisible. Dashboards that depend on it show wrong answers with zero signal that anything went wrong.
- **How to detect it:** You need cardinality anomaly detection or NULL-rate alerts on dependent tables, not error-rate alerts.

**Mode 2 — Hard error (the obvious one)**
- **Scenario:** Someone renames or drops a column you reference explicitly in a Trino query.
- **What happens:** Trino's planner sees the old column name in the stale cache and compiles the query successfully. But when Trino pushes the SQL down to Postgres, Postgres receives a reference to a column that no longer exists: `ERROR: column "plan_type" does not exist`. The query fails hard every time, on every call, until you fix it.
- **How to detect it:** Error-rate alerts on Trino queries will catch this immediately.

---

### The critical limitation of caching

The confusing part: if your cache TTL is 60 seconds, you don't just wait 60 seconds for it to refresh. During those 60 seconds, queries referencing the renamed column at the Trino planner level may pass planning but fail at the Postgres layer — you get intermittent, confusing errors where the exact same query succeeds and fails depending on which coordinator it hits.

---

### How to force an immediate refresh (no restart needed)

Don't wait for the TTL. Run this from any Trino SQL client:

```sql
CALL app_pg.system.flush_metadata_cache();
```

Replace `app_pg` with whatever you named your PostgreSQL catalog. This invalidates the in-memory metadata cache immediately — the next query repopulates it from Postgres. **No pod restart. No coordinator reload. Hot operation.**

**Critical note:** The PostgreSQL connector's `flush_metadata_cache()` procedure takes **no parameters** — do NOT try to pass `schema_name => 'public'` or `table_name => 'accounts'` (those named parameters only work on Hive and Delta Lake connectors). On PostgreSQL, the procedure is parameterless.

---

### The production checklist after a schema change

1. **Check if caching is on.** Look at `etc/catalog/app_pg.properties`. If `metadata.cache-ttl` is `0s` or absent, schema caching is OFF and you can ignore the rest. If it's `60s` or higher, proceed.
2. **Flush the cache immediately.** Run `CALL app_pg.system.flush_metadata_cache();` from any Trino client.
3. **Update any Trino views** that reference the old column name — flushing the cache fixes direct table queries, but Trino views have a frozen column schema that needs to be rewritten: `CREATE OR REPLACE VIEW my_view AS SELECT new_name, ... FROM app_pg.public.table;`
4. **Coordinate with dashboards and saved queries** — flushing the Trino cache doesn't fix their SQL. Users with saved queries referencing the old column name still have to update them.
5. **Verify:** Run `DESCRIBE app_pg.public.accounts;` to confirm Trino now sees the new schema.

---

### Trade-off for your stack

For a stable SaaS Postgres schema with infrequent migrations, the production standard is `metadata.cache-ttl=60s` + `metadata.cache-missing=true`. This drastically reduces metadata-query load on your Postgres replica while keeping the refresh window short enough that `flush_metadata_cache()` is a quick, non-disruptive fix when DDL happens.

If your team is doing frequent schema migrations, keep `metadata.cache-ttl=0s` and accept the metadata-query load. The schema is always fresh and no flush is ever needed.
