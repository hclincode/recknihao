# Iter282 Q2 — UUID and JSONB Type Mapping in Trino

## Answer

Both types work out of the box — no configuration needed. The "plain string" appearance of JSONB in results is just the display format. Here's how each type works and what functions to use.

### UUIDs — Native UUID Type, No Conversion

Postgres `uuid` columns map natively to Trino's `UUID` type. Trino understands UUIDs as first-class values. The key rule: when you filter or join on UUID columns, cast your literals to UUID type:

```sql
-- Correct: use UUID literal syntax
SELECT id, name FROM app_pg.public.accounts
WHERE tenant_id = UUID '11111111-2222-3333-4444-555555555555';

-- Also correct: explicit CAST
WHERE tenant_id = CAST('11111111-2222-3333-4444-555555555555' AS UUID);

-- WRONG: bare string — Trino treats it as VARCHAR, predicate won't push down
WHERE tenant_id = '11111111-2222-3333-4444-555555555555'
```

Without the cast, Trino compares UUID against VARCHAR — the types don't match, the predicate won't push down, and Postgres fetches all rows.

### JSONB — Maps to Trino JSON Type

Postgres `jsonb` (and `json`) maps natively to Trino's `JSON` type. This is why the column looks like a string when you `SELECT *` — Trino displays the JSON value as its serialized text representation. But internally the column IS a `JSON` type, and you use Trino's JSON functions directly on it.

**Extracting values from your `settings` column:**

```sql
-- Extract a string value: "plan": "pro" → returns VARCHAR
SELECT id, json_extract_scalar(settings, '$.plan') AS plan_type
FROM app_pg.public.accounts;

-- Extract a numeric value: "seats": 10 → returns the native type
SELECT id, json_extract(settings, '$.seats') AS seat_count
FROM app_pg.public.accounts;

-- Cast if you need a specific type
SELECT id, CAST(json_extract(settings, '$.seats') AS INTEGER) AS seat_count
FROM app_pg.public.accounts;
```

**Key distinction:**
- `json_extract_scalar(col, path)` — always returns `VARCHAR` (the string representation)
- `json_extract(col, path)` — returns the native JSON value type (numeric, boolean, string as JSON)

**Other useful JSON functions:**
```sql
-- Check the length of a JSON array
SELECT json_array_length(event_list) AS event_count FROM ...;

-- NULL check (JSON column is valid)
SELECT * FROM accounts WHERE settings IS NOT NULL;
```

### Critical Limitation: JSONB Predicates Don't Push Down

Filters on JSON-typed columns do NOT push down to Postgres over JDBC. This query:
```sql
WHERE json_extract_scalar(settings, '$.plan') = 'pro'
```
causes Trino to fetch the entire table across JDBC, then filter on workers. Trino's JSON functions run on the Trino side, not Postgres's side.

**If you need server-side JSONB filtering** (with index support), use `system.query()` to send Postgres-native JSONB operators verbatim:

```sql
SELECT * FROM TABLE(app_pg.system.query(
  query => 'SELECT id, settings FROM public.accounts WHERE settings->>''plan'' = ''pro'''
));
```

Single quotes inside the query string are doubled (`''`). This sends the native `->>`  operator to Postgres, which can use a JSONB GIN index.

### Type Mapping Summary

| Postgres type | Trino type | Extraction | Pushdown |
|---|---|---|---|
| `uuid` | `UUID` | Direct comparison with `UUID '...'` literal | Yes (equality, equality-on-UUID) |
| `jsonb` / `json` | `JSON` | `json_extract_scalar()`, `json_extract()` | No — full JDBC pull, then filter in Trino |

**For heavy JSONB analytics** (high-volume filtering on JSONB fields), the right long-term pattern is to ingest the Postgres table into Iceberg and denormalize the JSONB fields into explicit columns during ingestion. That eliminates the JDBC full-table-scan problem and gives you columnar pruning on the extracted fields.
