# Iter268 Q2 — Postgres Column Types Not Showing Up Right in Trino

## Answer

Yes, Trino is silently converting and dropping some of your PostgreSQL column types. Here is exactly what is happening with each type and how to fix it.

### UUID: Correctly Mapped to Trino's UUID Type

Your `uuid` column is being mapped correctly to Trino's **UUID** type — not VARCHAR. It looks like a string when displayed, but it is a proper UUID type internally. To verify:

```sql
DESCRIBE app_pg.public.users;
```

Look for `uuid` in the Type column. When writing filters, cast the literal to UUID so the predicate pushes down to Postgres:

```sql
-- Correct — filter pushes to Postgres
WHERE user_id = UUID '550e8400-e29b-41d4-a716-446655440000'

-- Wrong — Trino treats it as VARCHAR and may not push the filter
WHERE user_id = '550e8400-e29b-41d4-a716-446655440000'
```

### JSONB: Shows Up as JSON, But Field Filters Don't Push to Postgres

Postgres `jsonb` columns map to Trino's **JSON** type and are not dropped. You can read the whole value:

```sql
SELECT user_metadata FROM app_pg.public.users LIMIT 5;
```

However, Trino does not push JSONB field extraction back to Postgres. If you use `json_extract_scalar(user_metadata, '$.plan_tier')`, Trino fetches the entire column from Postgres and does the extraction on Trino workers — no server-side filtering.

If you need Postgres to do the filtering (for performance), use `system.query()` to run native Postgres SQL:

```sql
SELECT * FROM system.query(
  catalog => 'app_pg',
  schema  => 'public',
  sql     => 'SELECT id, user_metadata->>''plan_tier'' AS plan 
              FROM users 
              WHERE user_metadata->>''plan_tier'' = ''enterprise'''
);
```

This runs the entire query inside Postgres, including the JSONB filter.

### Array Columns: Silently Dropped by Default

This is the most confusing default. If you have a column like `tags TEXT[]` or `scores INTEGER[]`, it **does not appear in Trino at all** — no error, no warning. It is silently dropped because `postgresql.array-mapping=DISABLED` is the default.

**Confirm this is the issue:**
```sql
-- In Trino — notice which columns appear
DESCRIBE app_pg.public.your_table;

-- Then compare against what Postgres shows
-- (run in psql or system.query)
```

**Fix: enable arrays in the catalog config file** (`etc/catalog/app_pg.properties`):

```properties
postgresql.array-mapping=AS_ARRAY
```

Then restart the Trino coordinator and workers. Array columns now appear as `ARRAY<VARCHAR>`, `ARRAY<BIGINT>`, etc., and you can query them with standard array functions.

**Per-session alternative (no restart needed):**

```sql
SET SESSION app_pg.array_mapping = 'AS_ARRAY';
SELECT * FROM app_pg.public.your_table;
```

### Other Missing Columns: Unsupported Types Silently Ignored

Beyond arrays, Postgres custom types (range types like `tsrange`, geometric types, hstore, domain types) are also silently dropped. The default behavior is `postgresql.unsupported-type-handling=IGNORE`.

To surface these columns as VARCHAR (the Postgres text representation):

```properties
# etc/catalog/app_pg.properties
postgresql.unsupported-type-handling=CONVERT_TO_VARCHAR
```

After restarting, those columns reappear as `VARCHAR`. Not type-safe, but at least visible.

### How to See What Trino Sees vs. What Postgres Has

**Quick column check:**
```sql
DESCRIBE app_pg.public.your_table;
```

Any column missing from this output is being dropped by the connector.

**Detailed column listing:**
```sql
SELECT column_name, data_type
FROM app_pg.information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'your_table'
ORDER BY ordinal_position;
```

### Quick Reference: Postgres Types in Trino

| Postgres Type | Trino Type | Visible by Default? |
|---|---|---|
| `INTEGER`, `BIGINT`, `TEXT`, `VARCHAR`, `BOOLEAN` | Same | Yes |
| `UUID` | `UUID` | Yes |
| `NUMERIC` / `DECIMAL` | `DECIMAL` | Yes |
| `TIMESTAMP WITH TIME ZONE` | `TIMESTAMP WITH TIME ZONE` | Yes |
| `jsonb`, `json` | `JSON` | Yes (no server-side field filtering) |
| `TEXT[]`, `INTEGER[]`, `BOOLEAN[]` | `ARRAY<VARCHAR>`, etc. | No — enable with `postgresql.array-mapping=AS_ARRAY` |
| Range types, hstore, geometric types | Dropped | No — enable with `postgresql.unsupported-type-handling=CONVERT_TO_VARCHAR` |

### Action Checklist

1. Run `DESCRIBE app_pg.public.your_table` and note any missing columns
2. For each missing array column: add `postgresql.array-mapping=AS_ARRAY` to `etc/catalog/app_pg.properties` and restart
3. For any other missing columns: add `postgresql.unsupported-type-handling=CONVERT_TO_VARCHAR` and restart
4. For JSONB field filtering at scale: use `system.query()` to push filtering into Postgres
5. For UUID filters: always use `UUID '...'` cast to ensure predicate pushdown
