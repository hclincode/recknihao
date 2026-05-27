# Iter280 Q1 — Postgres jsonb and Unsupported Type Handling in Trino

## Answer

Good news: Trino supports jsonb natively. The issue is almost certainly an adjacent column with an unsupported type that's being silently dropped — here's how to diagnose and fix it.

### 1. jsonb Maps to Trino JSON Type Natively

PostgreSQL `jsonb` (and `json`) columns map directly to Trino's `JSON` type automatically. No configuration needed. jsonb is NOT routed through the unsupported-type-handling property — it's a first-class mapping.

### 2. The Silent Column Drop Problem

The PostgreSQL connector has a catalog property `postgresql.unsupported-type-handling` that defaults to `IGNORE`. When set to `IGNORE`, any column whose type Trino cannot map (such as `hstore`, range types, `citext`, geometric types, or certain array types) is **silently dropped during schema inference**. No error, no warning — the column simply doesn't appear in `SELECT *` or `DESCRIBE` results.

Your table may have jsonb (fine) plus some other column with an unsupported type. Trino drops the unsupported column silently and you're seeing jsonb's absence as a symptom when it's actually a different column causing the confusion.

### 3. How to Detect Silently Dropped Columns

Compare schema in two places:

**In Postgres:**
```sql
\d public.users;
```

**In Trino:**
```sql
DESCRIBE app_pg.public.users;
```

Any column present in Postgres but absent from Trino is being silently dropped. The missing column's Postgres type is unsupported.

**Quick diagnostic via debug logging** — in `/etc/log.properties` on coordinator:
```properties
io.trino.plugin.jdbc=DEBUG
```
Restart coordinator, run a query. Look for: `Unsupported type: <type> on column users.<column_name>`. Revert to `INFO` immediately after — very verbose in production.

### 4. Fix: CONVERT_TO_VARCHAR

Add to `etc/catalog/app_pg.properties`:
```properties
postgresql.unsupported-type-handling=CONVERT_TO_VARCHAR
```

After coordinator/worker restart, previously-hidden columns appear as `VARCHAR` with their Postgres text-cast representation. For example, `hstore` columns appear as strings like `"key"=>"value"`, range types as `[1,10)`.

For a quick test without restarting:
```sql
SET SESSION app_pg.unsupported_type_handling = 'CONVERT_TO_VARCHAR';
```

Note the naming convention: catalog file uses hyphens (`postgresql.unsupported-type-handling`); session property uses underscores (`app_pg.unsupported_type_handling`).

### 5. Custom Postgres ENUM Types

Custom ENUM types (like `CREATE TYPE subscription_status AS ENUM ('active', 'past_due', ...)`) are supported natively — they map directly to Trino `VARCHAR` with the text label coming through as a string. No configuration needed. This is correct behavior, not a bug.

### 6. Array Types

Array columns have a separate configuration: `postgresql.array-mapping` (default: `DISABLED` — silently drops array columns).

- **`AS_ARRAY`**: single-dimensional arrays → Trino `ARRAY<T>`. `INTEGER[]` becomes `ARRAY<INTEGER>`.
- **`AS_JSON`**: multi-dimensional arrays → Trino `JSON` for parsing on the Trino side.

```properties
# etc/catalog/app_pg.properties
postgresql.array-mapping=AS_ARRAY
```

Session form (no restart):
```sql
SET SESSION app_pg.array_mapping = 'AS_ARRAY';
```

### Next Steps

1. Run `\d public.users` in Postgres vs `DESCRIBE app_pg.public.users` in Trino — find the missing columns.
2. Enable JDBC DEBUG logging to identify the exact offending type.
3. Add `postgresql.unsupported-type-handling=CONVERT_TO_VARCHAR` and restart.
4. If you have array columns, add `postgresql.array-mapping=AS_ARRAY` for standard single-dimension arrays.
5. Verify with `DESCRIBE` again — all previously-dropped columns should appear.

Your jsonb column will be fine throughout — it's a native mapping.
