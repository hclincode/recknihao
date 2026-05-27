# Iter270 Q2 — Running Postgres-Specific SQL Through Trino: system.query() Passthrough

## Answer

Yes, this is real. Trino's PostgreSQL connector provides a table function called `system.query()` that sends a raw SQL string directly to Postgres and returns the results as a Trino table. It lets you use any Postgres-specific operator — including JSONB operators like `->>` and `?` — without Trino parsing them.

### The Syntax (Three Critical Rules)

```sql
SELECT * FROM TABLE(
  app_pg.system.query(
    query => 'SELECT id, settings->>''theme'' AS theme
              FROM public.user_prefs
              WHERE settings ? ''theme'''
  )
);
```

Three things you must get right:
1. **Wrap in `TABLE(...)`** — it is a polymorphic table function
2. **Catalog is part of the function path** (`app_pg.system.query`), not an argument
3. **Single quotes inside the SQL string must be doubled** — `'theme'` becomes `''theme''`

The parameter is named `query` (not `sql`).

### JSONB Examples

```sql
-- Extract JSONB field as text
SELECT * FROM TABLE(
  app_pg.system.query(
    query => 'SELECT id, data->>''plan_id'' AS plan_id FROM public.accounts'
  )
);

-- Filter rows containing a key (JSONB ? operator)
SELECT * FROM TABLE(
  app_pg.system.query(
    query => 'SELECT id, settings FROM public.users WHERE settings ? ''notifications'''
  )
);

-- Nested JSONB path
SELECT * FROM TABLE(
  app_pg.system.query(
    query => 'SELECT id, metadata#>>array[''config'',''region''] AS region
              FROM public.tenants'
  )
);
```

### When to Use system.query() vs Trino-Native

| Situation | Use |
|---|---|
| JSONB operators (`?`, `@>`, `->>`, `#>>`) | `system.query()` — Trino has no equivalent |
| Postgres full-text search (`@@`) | `system.query()` — Trino has no full-text search |
| Range operators (`@>`, `<@`, `&&`) | `system.query()` — Trino has no range types |
| Simple JSONB field extraction (no server-side filtering needed) | Trino-native `json_extract_scalar(col, '$.key')` |
| Equality filter on a VARCHAR column | Trino-native — predicate pushes to Postgres |
| Large table with JSONB filter (millions of rows) | `system.query()` — Postgres filters server-side |

### Critical Limitation: No Outer Predicate Pushdown

When you add a WHERE clause outside the `TABLE(...)`, Trino fetches the entire result set first and then filters:

```sql
-- BAD: fetches all rows, then Trino filters
SELECT * FROM TABLE(
  app_pg.system.query(
    query => 'SELECT id, settings FROM users'
  )
)
WHERE settings ? 'notifications';  -- runs on Trino, not Postgres!

-- GOOD: filtering inside the string runs on Postgres
SELECT * FROM TABLE(
  app_pg.system.query(
    query => 'SELECT id, settings FROM users WHERE settings ? ''notifications'''
  )
);
```

Always push your filters **inside the SQL string**. Whatever filter you need must be in the Postgres SQL, not in an outer Trino WHERE clause.

### Other Limitations

1. **Schema inferred from first row** — if the first row has NULL values, Trino may infer wrong types
2. **Empty results break schema inference** — avoid for automated pipelines that may return zero rows
3. **ORDER BY not guaranteed** — Trino may reorder rows during distributed execution; add an explicit ORDER BY in the outer Trino query if sort order matters
4. **No cross-catalog joins inside the function** — join in the outer Trino query instead:

```sql
-- Join system.query() result to Iceberg table
SELECT i.event_id, pg.plan_id
FROM iceberg.analytics.events i
JOIN TABLE(
  app_pg.system.query(
    query => 'SELECT id, settings->>''plan_id'' AS plan_id FROM public.users'
  )
) AS pg(id, plan_id)
ON i.user_id = pg.id;
```

### Is It Safe for Production?

Yes, it is documented and supported in Trino 467. Points to know:

- **Access control**: OPA treats `system.query()` as `ExecuteFunction` — your OPA policy can restrict who can call it
- **Credentials**: runs as the catalog's configured Postgres user (set in `etc/catalog/app_pg.properties`) — same access level for all callers
- **No SQL injection protection**: the SQL string goes directly to Postgres; your application must not build the query string from untrusted user input

### Decision Guide

1. **Try Trino-native first** — if `json_extract_scalar(col, '$.key')` works and you don't need server-side filtering, use it
2. **Use `system.query()` when** Postgres-specific operators are required AND you need the filter to run on Postgres (not fetching all rows)
3. **Use `system.query()` sparingly** — it bypasses Trino's optimizer, parallelism, and caching; it doesn't benefit from dynamic filtering when joining against Iceberg

For your JSONB `->>` case: if you just need to extract the value without a server-side filter, `json_extract_scalar` works fine. If you need to filter rows where the JSONB field has a specific value AND the table is large (millions of rows), use `system.query()` to push the filter into Postgres.
