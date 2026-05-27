# Iter 186 Q2 — system.query() Table Function for pg_catalog Access

## Answer

The good news is that **Trino is NOT blind to `pg_catalog` — you have two escape hatches to query Postgres system catalogs** from within Trino without leaving the federated model. Your error when trying `SELECT * FROM billing_pg.pg_catalog.pg_type` suggests those schemas are simply not exposed yet. Here's how to fix it.

### Option 1: Enable system table exposure (recommended for regular access)

If you need to query `pg_catalog` **frequently** (e.g., a monitoring dashboard that checks for custom enum types regularly), add this **catalog property** to your `etc/catalog/billing_pg.properties`:

```properties
postgresql.include-system-tables=true
```

After the Trino **coordinator restart**, `pg_catalog` becomes a queryable schema under your catalog:

```sql
SHOW SCHEMAS FROM billing_pg;
-- pg_catalog will now appear in the list

SELECT typname, typtype
FROM billing_pg.pg_catalog.pg_type
WHERE typtype = 'e'  -- 'e' = enum types
ORDER BY typname;
```

**Trade-off**: This clutters `SHOW SCHEMAS` with dozens of Postgres internals you don't usually care about (pg_index, pg_class, pg_attribute, etc.), but it's the cleanest approach for repeatable queries.

### Option 2: Use `system.query()` (recommended for one-offs)

If you need to query `pg_catalog` **occasionally** or want to avoid a coordinator restart, use the **`system.query()` table function** — it sends raw Postgres SQL directly to your billing database without requiring any config changes:

```sql
SELECT * FROM TABLE(
  billing_pg.system.query(
    query => 'SELECT typname, typtype FROM pg_catalog.pg_type WHERE typtype = ''e'''
  )
);
```

This is the escape hatch designed exactly for this use case. **Key points:**

- The SQL string is sent verbatim to Postgres — you write native Postgres syntax, and Postgres executes it server-side.
- **No restart or config change needed** — you can run this immediately.
- The result comes back to Trino as a regular table, so you can wrap it in a Trino view if you want to give other users an easy name to query.
- It's available on all JDBC connectors (PostgreSQL, MySQL, SQL Server, Oracle) in Trino 467, same pattern across all of them.

### Which to pick?

| Scenario | Use |
|---|---|
| One-off diagnostic: "what custom enums exist in billing_pg right now?" | `system.query()` — run once, no config needed |
| Automated job or dashboard that queries pg_catalog regularly | `postgresql.include-system-tables=true` — enable permanently, then query normally |

### Why your original query failed

When you tried `SELECT * FROM billing_pg.pg_catalog.pg_type`, Trino couldn't find `pg_catalog` as a schema because the PostgreSQL connector defaults to exposing **only user-facing schemas** (the ones you'd normally back up or restore). System catalogs are hidden by default to avoid cluttering the schema list with Postgres internals. The two options above are the officially supported ways to expose them.

**Production context note**: Your production environment points Trino at a **read replica** of your billing database, so these queries are safe — they won't load the primary. Both options respect that read-only intent.
