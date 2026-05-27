# Iter261 Q1 — Postgres Column Type Mapping in Trino: jsonb, uuid, timestamp with time zone, text[]

## Answer

Your question hits one of the most-confusing aspects of federated queries. The good news: **most of your column types are supported**. The tricky part is understanding which ones Trino handles natively vs. which require configuration or workarounds.

### Your Specific Column Types — The Verdict

| Your column type | Trino behavior | Will filters/queries work? | What you need to know |
|---|---|---|---|
| **`uuid` primary key** | Native support — maps to Trino `UUID` | YES. Equality and `IN` lists push down to Postgres for server-side filtering. | Works out of the box. Filtering on UUIDs is one of the well-supported predicates. |
| **`jsonb` metadata columns** | Native support — maps to Trino `JSON` | Partially. The column appears and values come through correctly, BUT **JSONB-specific operators like `?` (key exists), `@>` (contains), `->` (access) do NOT push down**. These filter on Trino workers, not in Postgres. | JSONB itself is supported natively. Filters evaluate on Trino side, not Postgres side. If you need server-side JSONB filtering, use the `system.query()` escape hatch (see below). |
| **`timestamp with time zone`** | Native support — maps to Trino `TIMESTAMP(6)` | YES. Equality and range predicates (`>`, `<`, `BETWEEN`) push down to Postgres. | Works out of the box for filtering. The timezone is preserved. |
| **`text[]` array columns** | **SILENTLY OMITTED by default** — the column disappears from `SELECT *` and `DESCRIBE` with no error | NO — column doesn't appear at all | **This is the gotcha.** Arrays of supported scalar types (`TEXT[]`, `INTEGER[]`, `BOOLEAN[]`) are controlled by a SEPARATE property: `postgresql.array-mapping`. The default is `DISABLED`, which silently drops them. Enable with configuration (see below). |

### The Silent-Drop Problem — Why Your Arrays Vanish

This is Trino's most confusing default. When you run `SELECT * FROM your_table` and a `text[]` column is present in Postgres but missing from the Trino result, you haven't hit a bug — **the column was intentionally dropped during schema inference** because the default `postgresql.array-mapping=DISABLED` tells Trino not to map arrays.

The same silent-drop behavior applies to genuinely unsupported types (range types like `tsrange`, `hstore`, geometric types like `POLYGON`, arrays of `timestamp with time zone`, custom domains, etc.). These are controlled by `postgresql.unsupported-type-handling=IGNORE` (the default), which silently drops columns with no error and no entry in `DESCRIBE`.

**Diagnostic check — run this:**

```sql
-- In Trino
DESCRIBE app_pg.public.your_table;
-- Compare the column list to:

-- In Postgres (psql)
\d public.your_table
-- Any column present in Postgres but ABSENT from the Trino DESCRIBE is being silently dropped.
```

### Fix Your Arrays — Enable `postgresql.array-mapping`

To make your `text[]` columns readable in Trino:

**Option 1: Catalog-wide (persistent, requires coordinator restart)**

Add this to `etc/catalog/app_pg.properties`:

```properties
# etc/catalog/app_pg.properties
connector.name=postgresql
connection-url=jdbc:postgresql://...
# ... other properties ...

# Enable array mapping
postgresql.array-mapping=AS_ARRAY
```

Then restart the Trino coordinator and workers.

**Option 2: Per-session (no restart, only lasts for your current session)**

```sql
SET SESSION app_pg.array_mapping = 'AS_ARRAY';
-- Now your SELECT queries will include the array columns.
SELECT * FROM app_pg.public.your_table LIMIT 5;
```

Once enabled, `text[]` columns appear as Trino `ARRAY<VARCHAR>` and you can query them — though note that **array predicates do not push down to Postgres**. Filtering on array contents (e.g., `WHERE 'tag1' = ANY(tags_array)`) happens on Trino workers, not in Postgres.

### JSONB Filtering — A Subtle Limitation

Your `jsonb` columns work, but there's an important caveat: **JSONB operators don't push down**. If you write a Postgres-style filter like this:

```sql
-- This does NOT push down to Postgres
SELECT * FROM app_pg.public.customers
WHERE metadata @> '{"plan": "enterprise"}'::jsonb;
```

Trino will fetch the entire `metadata` column from Postgres (all rows), then apply the `@>` operator in-memory on its workers. This defeats the purpose of pushing filters to Postgres. **The column appears, the value is readable, but the filter is not server-side.**

**If you need server-side JSONB filtering**, use the `system.query()` escape hatch — it passes the entire query to Postgres for native execution:

```sql
-- Server-side JSONB filtering using system.query()
SELECT * FROM TABLE(
  app_pg.system.query(
    query => 'SELECT id, customer_id, metadata
              FROM customers
              WHERE metadata @> ''{"plan": "enterprise"}''::jsonb'
  )
);
```

The downside: you lose Trino's distributed query engine for this query. It all executes in Postgres. But the filter is applied in the database, not over the network.

### Quick Reference — What Pushes Down, What Doesn't

**Predicates that DO push down to Postgres:**

- Equality on UUID columns: `WHERE tenant_id = 'a1b2c3d4-...'`
- `IN` lists on UUID: `WHERE tenant_id IN ('uuid1', 'uuid2', ...)`
- Equality and range on `timestamp with time zone`: `WHERE created_at > TIMESTAMP '2026-05-01 00:00:00'`
- `IN` lists on timestamps

**Predicates that do NOT push down:**

- JSONB-specific operators (`@>`, `?`, `->`, etc.) — evaluate on Trino workers
- Array membership tests (`WHERE tags @> ARRAY['tag1']`) — evaluate on Trino workers
- Complex JSONB path traversals — stay on Trino side

**Verify what pushes down with `EXPLAIN`:**

```sql
EXPLAIN SELECT * FROM app_pg.public.your_table
WHERE metadata @> '{"plan": "enterprise"}'::jsonb;
```

Look for `constraint on [metadata]` in the output — if it's missing, the filter didn't push down.

### When to Use `system.query()` for the Full Postgres Experience

If you find Trino's handling of a type limiting, **`system.query()` bypasses all translation and sends raw SQL directly to Postgres**. Use it when:

- You need Postgres-specific operators (JSONB `@>`, `?`; range type `@>`; hstore `?`; full-text `@@`, etc.)
- You need Postgres functions (e.g., `jsonb_extract_text()`, `jsonb_agg()`, etc.)

```sql
SELECT * FROM TABLE(
  app_pg.system.query(
    query => 'SELECT id, customer_id, tags
              FROM customers
              WHERE tags @> ARRAY[''premium'']'  -- native Postgres array operator
  )
);
```

### Summary — Your Action Items

1. **For `uuid`, `timestamp with time zone`, `jsonb` columns**: they work out of the box. Filtering on UUID and timestamp pushes down; JSONB filtering does not (use `system.query()` if you need server-side JSONB).

2. **For `text[]` array columns**: enable `postgresql.array-mapping=AS_ARRAY` in your catalog properties and restart, OR use `SET SESSION app_pg.array_mapping = 'AS_ARRAY'` per-session.

3. **Verify with `DESCRIBE`**: after enabling arrays, run `DESCRIBE app_pg.public.your_table` and compare to `\d` in Postgres. If columns are still missing, you've hit a genuinely unsupported type — in that case, set `postgresql.unsupported-type-handling=CONVERT_TO_VARCHAR` to read them as text strings, or use `system.query()` to handle them server-side.

4. **Test filtering with `EXPLAIN`**: run `EXPLAIN` on your most complex filters to confirm which predicates are pushing down (should show `constraint on [column_name]` in the Postgres `TableScan` node).
