# Iter 203 Q1 — PostgreSQL Arrays, ENUMs, and JSONB in Trino Federation

## Answer

Based on your schema with `TEXT[]`, `INTEGER[]`, custom ENUM types (`subscription_status`), and JSONB columns, here's exactly what happens when you query through Trino and how to fix it.

### 1. Type Mapping: What Trino Does With Each PostgreSQL Type

**TEXT[] and INTEGER[] (PostgreSQL arrays)**

By default, Trino's PostgreSQL connector has `array_mapping` set to `DISABLED`, which means array columns are **skipped entirely** — they won't appear in your query results at all. You won't get an error; the columns just vanish from `SELECT *`.

When you enable array mapping, you have two choices:
- `array_mapping = AS_ARRAY`: Maps Postgres `TEXT[]` to Trino `ARRAY<VARCHAR>` and `INTEGER[]` to Trino `ARRAY<BIGINT>`. You can then use Trino's array functions like `element_at()`, `cardinality()`, `contains()` to work with them.
- `array_mapping = AS_JSON`: Maps arrays to Trino's `JSON` type instead. This is useful if you want to store them as JSON but doesn't let you use native array functions.

**ENUM types (like `subscription_status`)**

Custom ENUM types fall into PostgreSQL's "vendor-specific" category. Trino doesn't natively understand your `subscription_status` enum with its `trialing`, `active`, `past_due`, `canceled` values. By default, `unsupported_type_handling` is set to `IGNORE`, which means:
- The ENUM column is **skipped** — it won't appear in your result set at all.
- No error is raised; it's silent column exclusion.

**JSONB columns**

JSONB is **fully supported**. The PostgreSQL connector maps Postgres `jsonb` to Trino's `JSON` type. Your metadata blobs will come through as Trino `JSON` objects, and you can use Trino's JSON extraction functions like `json_extract_scalar()`, `json_extract()`, and `json_array_length()` to work with them.

---

### 2. The `unsupported_type_handling` Session Property

This property controls what happens when Trino encounters a Postgres type it doesn't natively understand (ENUMs, geometric types like `POLYGON`, custom domains, etc.):

| Value | Behavior | When to use |
|-------|----------|------------|
| `IGNORE` | Skip the column entirely — it won't appear in `SELECT *` or schema introspection. No error is raised. | (default) Safe but frustrating — if you need the column, you must switch to `CONVERT_TO_VARCHAR`. |
| `CONVERT_TO_VARCHAR` | Read the column as a text string. The ENUM's text representation (e.g., `"active"`, `"past_due"`) comes through as `VARCHAR`. You lose enum type safety but gain access to the data. | When you need to read unsupported columns as strings. Your application can parse them downstream. |

**Setting it per-session:**
```sql
SET SESSION app_pg.unsupported_type_handling = 'CONVERT_TO_VARCHAR';
```

(Replace `app_pg` with your actual Postgres catalog name.)

**Setting it globally in the catalog config:**
Add to `etc/catalog/app_pg.properties`:
```properties
unsupported-type-handling=CONVERT_TO_VARCHAR
```

Then restart the Trino coordinator (or use dynamic catalog reload if available).

---

### 3. What "Errors" vs. "Weird String Values" Correspond To

**"Errors" you're seeing:**
- If you try to query an ENUM column with `unsupported_type_handling = IGNORE` (default), the column doesn't exist in Trino's schema. You get a **"column not found"** error when you try to reference it by name.
- Example: `SELECT subscription_status FROM app_pg.public.users` fails with `Column 'subscription_status' cannot be resolved`.

**"Weird string values" you're seeing:**
- If you set `unsupported_type_handling = CONVERT_TO_VARCHAR`, the ENUM comes back as a plain text string: `"active"`, `"past_due"`, `"canceled"`, etc. These are the enum's text labels, not errors — but they're VARCHAR, so you can only filter and group by the string value.
- Example: `SELECT subscription_status FROM app_pg.public.users WHERE subscription_status = 'active'` works fine and returns rows where the ENUM value is `active`.

---

### 4. Practical Recommendations for Your Schema

**For TEXT[] (feature flags) and INTEGER[] (workspace IDs):**

Add this to `etc/catalog/app_pg.properties`:
```properties
array-mapping=AS_ARRAY
```

Then restart. Now your queries see these as native Trino arrays:

```sql
-- Query feature flags (TEXT[])
SELECT user_id, element_at(feature_flags, 1) AS first_flag
FROM app_pg.public.users
WHERE cardinality(feature_flags) > 0;

-- Query workspace IDs (INTEGER[])
SELECT tenant_id, contains(workspace_ids, 123) AS has_workspace_123
FROM app_pg.public.users
WHERE cardinality(workspace_ids) >= 1;
```

If your application needs to filter by array membership at the Postgres level (for performance), use `system.query()` to send native Postgres syntax:

```sql
SELECT * FROM TABLE(app_pg.system.query(
  query => 'SELECT * FROM public.users WHERE feature_flags @> ARRAY[''feature_x'']'
));
```

**For ENUM (`subscription_status`):**

Add this to `etc/catalog/app_pg.properties`:
```properties
unsupported-type-handling=CONVERT_TO_VARCHAR
```

The column will now appear as a VARCHAR. You can filter and group by it normally:

```sql
SELECT subscription_status, COUNT(*) AS user_count
FROM app_pg.public.users
GROUP BY subscription_status;
```

**Note**: The text values (`'active'`, `'past_due'`, etc.) come through as strings. You don't get enum-level type safety in Trino, but you get the data.

**For JSONB columns:**

No configuration needed — they already work. Use Trino's JSON functions:

```sql
SELECT id, json_extract_scalar(metadata, '$.event_type') AS event_type
FROM app_pg.public.events
WHERE json_extract_scalar(metadata, '$.plan_tier') = 'premium';
```

**Important caveat on JSONB filtering**: The filter above executes on Trino workers **after fetching all rows from Postgres** — it does NOT push down to the server. For large tables with expensive JSONB filters, use `system.query()` to run the filter in Postgres instead:

```sql
SELECT * FROM TABLE(app_pg.system.query(
  query => 'SELECT * FROM public.events WHERE metadata @> ''{"plan_tier": "premium"}''::jsonb'
));
```

---

### Summary: Configuration Changes Required

Add this to `etc/catalog/app_pg.properties` and restart Trino:

```properties
# Enable array columns (TEXT[] and INTEGER[])
array-mapping=AS_ARRAY

# Read unsupported types (ENUM, custom domains) as VARCHAR strings
unsupported-type-handling=CONVERT_TO_VARCHAR
```

With these settings:
- TEXT[] and INTEGER[] columns become queryable as Trino ARRAY types
- subscription_status (ENUM) appears as VARCHAR — no type safety, but readable
- JSONB continues to work as Trino JSON
- All columns are now accessible through normal Trino SQL

No schema restructuring needed — Trino adapts to your Postgres schema through these configuration flags.
