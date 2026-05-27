# Iter 185 Q2 — information_schema Discovery Across Federation Catalogs

## Answer

Based on the resources available, I can give you a direct answer to your schema discovery question, though with one important caveat about what the resources cover.

### Yes, you can query `information_schema.columns` through Trino's PostgreSQL connector

You can run something very close to what you described:

```sql
SELECT column_name, data_type 
FROM billing_pg.information_schema.columns 
WHERE table_schema = 'public';
```

This works because Trino's PostgreSQL connector mirrors the entire structure of your Postgres instance into Trino's catalog namespace — every Postgres schema becomes a Trino schema, every Postgres table becomes a Trino table, and the special `information_schema` schema that Postgres maintains is also available to query through Trino.

### The simpler Trino approach

For most schema discovery use cases, **Trino's own commands are actually more straightforward than `information_schema` queries**:

```sql
-- List all tables in a schema:
SHOW TABLES FROM billing_pg.public;

-- Describe a table (column names + types):
DESCRIBE billing_pg.public.your_table;
-- or equivalently:
SHOW COLUMNS FROM billing_pg.public.your_table;
```

These give you the same column-level type information (column name, data type) without writing a query against `information_schema`.

### The tradeoffs: Trino via federation vs. direct Postgres

| Aspect | Via `billing_pg.information_schema` through Trino | Direct connection to Postgres |
|--------|------|------|
| **Freshness** | Depends on Trino's schema cache setting (`metadata.cache-ttl`, default 0s). With caching disabled (default), you see current schema on every query. | Always current (no Trino cache layer). |
| **Performance** | Goes through the PostgreSQL connector's JDBC layer → pulls `information_schema.columns` rows over the network. Small query but adds JDBC overhead. | Direct SQL to Postgres — slightly faster for one-off checks. |
| **Completeness** | You get exactly what the PostgreSQL connector can see and expose through Trino's type system. Some Postgres-specific types (custom domains, geometric types) may be skipped or converted to VARCHAR depending on connector settings. | You see raw Postgres types including custom types, pg_catalog extensions, etc. Postgres's own `information_schema` is complete. |
| **Which gives a better picture?** | More aligned with **what Trino can actually query** — if a column is `IGNORE`d by the connector due to an unsupported Postgres type, Trino's `SHOW COLUMNS` won't see it, but direct Postgres `information_schema` will. | More complete view of the raw Postgres schema; useful for auditing *against* what Trino sees. |

### Why the difference matters

The resource on PostgreSQL federation explicitly flags that **unsupported Postgres types can be skipped entirely by the connector**. You can control this behavior with a connector session property:

```sql
SET SESSION billing_pg.unsupported_type_handling = 'CONVERT_TO_VARCHAR';
```

By default it is `IGNORE` — so if your Postgres table has a column with a custom domain or geometric type, `SHOW COLUMNS FROM billing_pg.public.table` will **not show that column at all**. But direct Postgres `SELECT * FROM information_schema.columns WHERE table_name = 'table'` will show it.

### Practical recommendation

- **For building queries in Trino**: use `SHOW COLUMNS` or `DESCRIBE` — it tells you exactly what Trino will allow you to project in a SELECT.
- **For auditing what Trino can *actually* see vs. what exists in Postgres**: compare the two. Run `SHOW COLUMNS` on the Trino side, then connect directly to Postgres and query `information_schema.columns` on the same table. If the two lists differ, you've found columns the connector is silently skipping (usually due to type incompatibility).
- **If you're debugging schema mismatches after a Postgres migration**: after a Postgres schema change (column rename, ADD/DROP), you may need to flush Trino's metadata cache with `CALL billing_pg.system.flush_metadata_cache()` before Trino sees the new schema. Direct Postgres queries always see the current schema immediately.

The resources don't cover Postgres's `pg_catalog` vs `information_schema` distinction specifically. For the purposes of discovering what Trino can query, `SHOW COLUMNS` through Trino is the authoritative answer.
