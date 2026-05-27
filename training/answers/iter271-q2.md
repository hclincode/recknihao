# Iter271 Q2 — Postgres Type Mapping in Trino: UUID, JSONB, Enums, and Silent Data Loss

## Answer

You're asking exactly the right question — silent data loss is the biggest risk when querying non-standard Postgres types through Trino. The short answer: UUID and JSONB both work natively and safely, and custom enums map to VARCHAR automatically. But the default behavior for *other* unsupported types is to drop them silently with no error.

### Your Three Column Types — Quick Verdict

| Column type | Trino behavior | Safe? | Configuration needed |
|---|---|---|---|
| `uuid` | Maps to Trino `UUID` type natively | Yes | None — but cast literals as `UUID '...'` in predicates |
| `jsonb` | Maps to Trino `JSON` type natively | Yes | None — use `system.query()` for complex JSONB predicates |
| Custom enum (`account_status`) | Maps to `VARCHAR` (text label) natively | Yes | None — native mapping, NOT via `unsupported-type-handling` |

**None of your three columns require special handling.** They all work out of the box.

### UUID: Safe, but Literal Casting Is Required

Postgres `uuid` columns map directly to Trino's native `UUID` type — not as a string coercion. When you query:

```sql
SELECT user_id FROM app_pg.public.users;
```

`user_id` arrives as a proper Trino `UUID`. This is correct and safe.

**However**, when filtering on UUID columns, you must cast literals correctly:

```sql
-- CORRECT: literal explicitly cast as UUID — predicate pushes to Postgres
SELECT user_id, email 
FROM app_pg.public.users 
WHERE user_id = UUID '11111111-2222-3333-4444-555555555555';

-- WRONG: literal treated as VARCHAR — predicate may not push efficiently
SELECT user_id, email 
FROM app_pg.public.users 
WHERE user_id = '11111111-2222-3333-4444-555555555555';
```

Always use `UUID '...'` syntax or `CAST('...' AS UUID)` in WHERE clauses.

### JSONB: Native JSON Support, but JSONB Filtering Has a Caveat

Postgres `jsonb` columns map to Trino's `JSON` type natively — the column appears in `SELECT *` and is NOT dropped. You can extract nested values with Trino JSON functions:

```sql
SELECT 
  id,
  metadata,
  json_extract_scalar(metadata, '$.customer_id') AS customer_id
FROM app_pg.public.events;
```

No configuration required.

**Important limitation**: JSONB columns cannot be used as Postgres-side filters through Trino directly. This:

```sql
-- Does NOT push down to Postgres
SELECT id FROM app_pg.public.events 
WHERE metadata->>'event_type' = 'purchase';
```

…will cause Trino to fetch every row's JSONB column over JDBC, then filter in-memory on workers. For large tables, this scans the entire table at full cost.

**Workaround for heavy JSONB filtering**: Use the `system.query()` table function to run Postgres-native JSONB operators server-side:

```sql
-- This DOES push down — Postgres evaluates the JSONB operators using its index
SELECT * FROM TABLE(
  app_pg.system.query(
    query => 'SELECT id, payload, created_at FROM public.events 
              WHERE payload ? ''event_type'' 
              AND payload->>''event_type'' = ''purchase'''
  )
);
```

The `?` (key exists) and `->>` operators are Postgres-specific and have no Trino equivalent, so `system.query()` is the only way to filter on them server-side.

### Custom Enums: Transparent VARCHAR Mapping

Your `account_status` enum maps to Trino `VARCHAR` automatically — the text label (`'active'`, `'pending'`, `'suspended'`) comes through as a plain string. This is **native support**, not routed through the `unsupported-type-handling` property.

```sql
SELECT user_id, account_status FROM app_pg.public.users;
-- account_status is VARCHAR with values like 'active', 'past_due'
```

Filtering on enums works correctly and predicate pushes to Postgres:

```sql
SELECT user_id, email FROM app_pg.public.users 
WHERE account_status = 'active';
```

### The Real Danger: Unsupported Types Are Silently Dropped

If your schema has columns with types Postgres supports but Trino doesn't recognize — `hstore`, range types (`tsrange`, `int4range`), geometric types (`POINT`, `POLYGON`), etc. — **those columns vanish silently from results with no error or warning**:

```sql
-- Table in Postgres has: id, name, metadata (jsonb), settings (hstore), feature_flags (text[])

DESCRIBE app_pg.public.users;
-- Returns: id, name, metadata
-- MISSING: settings (hstore), feature_flags (text[]) — no error!

SELECT * FROM app_pg.public.users;
-- Returns 3 columns, not 5. No error.

SELECT settings FROM app_pg.public.users;
-- Error: Column 'settings' cannot be resolved
-- (Trino dropped it, so now it looks like it doesn't exist in Postgres)
```

This is the default behavior because `postgresql.unsupported-type-handling` defaults to `IGNORE`. It is the most confusing failure mode in the Postgres connector.

### Two Properties Control This Behavior

**1. `postgresql.unsupported-type-handling` — for non-array unsupported types**

| Value | Behavior |
|---|---|
| `IGNORE` (default) | Unsupported columns disappear silently. No error. |
| `CONVERT_TO_VARCHAR` | Unsupported columns appear as Trino VARCHAR (Postgres text representation). Data is readable. |

**2. `postgresql.array-mapping` — for Postgres arrays specifically**

| Value | Behavior |
|---|---|
| `DISABLED` (default) | Postgres arrays silently vanish from results. |
| `AS_ARRAY` | Postgres arrays appear as Trino ARRAY types. `TEXT[]` → `ARRAY<VARCHAR>`, `INTEGER[]` → `ARRAY<BIGINT>`. |

Note: these are **two separate properties** — `array-mapping` controls scalar arrays (1-D `TEXT[]`, `INTEGER[]`, etc.); `unsupported-type-handling` controls everything else.

**Common unsupported types and their fix:**

| Postgres type | Problem | Fix |
|---|---|---|
| `hstore` | Key-value type, no Trino equivalent | `CONVERT_TO_VARCHAR` (renders as `"k"=>"v"`) |
| `tsrange`, `int4range`, `daterange` | Range types | `CONVERT_TO_VARCHAR` (renders as `[lower,upper)`) |
| `citext` | Case-insensitive text | `CONVERT_TO_VARCHAR` (VARCHAR, loses case-insensitivity) |
| `xml` | No Trino XML type | `CONVERT_TO_VARCHAR` (raw XML string) |
| `POINT`, `POLYGON`, geometric types | No Trino equivalent | `CONVERT_TO_VARCHAR` or denormalize to lat/lon columns in Iceberg |
| `TEXT[]`, `INTEGER[]`, `BOOLEAN[]` | Default: silently dropped | `postgresql.array-mapping=AS_ARRAY` |
| `INTEGER[][]` multi-dim arrays | No support | Use `system.query()` with Postgres-side unnest |

### What to Add to Your Catalog File

Edit `etc/catalog/app_pg.properties`:

```properties
connector.name=postgresql
connection-url=jdbc:postgresql://app-postgres-replica.app.svc.cluster.local:5432/appdb
connection-user=${ENV:APP_PG_USER}
connection-password=${ENV:APP_PG_PASSWORD}

# Make unsupported types readable as text instead of silently dropping them
postgresql.unsupported-type-handling=CONVERT_TO_VARCHAR

# Enable Postgres scalar arrays to come through as Trino ARRAY types
postgresql.array-mapping=AS_ARRAY
```

**Restart the Trino coordinator after editing catalog properties.**

To test without restarting, use session properties (note underscores instead of hyphens):

```sql
SET SESSION app_pg.unsupported_type_handling = 'CONVERT_TO_VARCHAR';
SET SESSION app_pg.array_mapping = 'AS_ARRAY';
-- Then run your query
```

### Diagnostic Flow: Columns Missing from Trino but Exist in Postgres

**Step 1: Count columns**
```sql
-- In Postgres (via system.query)
SELECT * FROM TABLE(
  app_pg.system.query(
    query => 'SELECT column_name, data_type 
              FROM information_schema.columns 
              WHERE table_name = ''users'' 
              ORDER BY ordinal_position'
  )
);

-- In Trino
DESCRIBE app_pg.public.users;
```

**Step 2: Compare. If Postgres has more columns, check the data types of the missing ones:**

| Missing type | Fix |
|---|---|
| `hstore`, `tsrange`, `citext`, `xml`, geometric | `postgresql.unsupported-type-handling=CONVERT_TO_VARCHAR` |
| `TEXT[]`, `INTEGER[]`, `BOOLEAN[]` | `postgresql.array-mapping=AS_ARRAY` |
| `INTEGER[][]` multi-dim | Use `system.query()` only |
| Custom enum | Should work natively — something else is wrong |
| `uuid`, `jsonb` | Should work natively — something else is wrong |

### Summary for Your Specific Columns

1. **`user_id` (uuid)** — Works natively as Trino `UUID`. Use `UUID '...'` literals in predicates. No config needed.

2. **`metadata` (jsonb)** — Works natively as Trino `JSON`. Extract with `json_extract_scalar()`. For server-side JSONB filtering, use `system.query()`. No config needed.

3. **`account_status` (custom enum)** — Works natively as Trino `VARCHAR`. The text label comes through. No config needed.

**Set `postgresql.unsupported-type-handling=CONVERT_TO_VARCHAR` and `postgresql.array-mapping=AS_ARRAY` regardless** — your current schema is safe, but as your Postgres schema evolves, any new unsupported type column will silently vanish without these settings. Set them once and avoid the problem permanently.
