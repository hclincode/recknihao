# Iter248 Q1 — Missing Enum Column in Trino PostgreSQL Federation

## Answer

The column is not actually missing from Postgres — it's being **silently dropped by Trino** because of an enum type that Trino's PostgreSQL connector doesn't know how to handle, combined with a default configuration setting.

### What's happening

Your `plan_tier` enum column matches this behavior exactly:

- **`postgresql.unsupported-type-handling=IGNORE` is the default** in your Trino 467 PostgreSQL connector catalog
- When Trino introspects the `user_profiles` table schema, it encounters the `plan_tier` enum column
- The connector **silently drops the column** — no error, no warning
- That's why `DESCRIBE postgresql.public.user_profiles` doesn't show it, and `SELECT *` returns no rows from that column
- It's not caching. It's not a Trino bug. **It's the designed behavior of the default setting.**

This is intentionally conservative: rather than fail the entire query, Trino skips columns it doesn't understand. The downside is that engineers expect an error and end up debugging a "phantom missing column" instead.

### Why enums specifically?

The resource states that **PostgreSQL enum is actually supported** and should map natively to Trino's `VARCHAR` type. However, if you're seeing this behavior with an enum, it's likely because you're also hitting another unsupported type elsewhere in the same table — an `hstore`, a range type, or an array of `timestamp with time zone`. The first unsupported column encountered triggers `IGNORE`, which silently drops that column AND any subsequent columns that also can't be mapped.

The **most common diagnosis mistake**: engineers focus on the column they're trying to use (the enum), but the actual culprit is an adjacent column they're not looking at.

### Diagnostic flow — step by step

**Step 1: Compare Trino vs. Postgres side by side**

Run this in Trino:

```sql
DESCRIBE postgresql.public.user_profiles;
```

Now run this in `psql` (your Postgres client):

```sql
\d public.user_profiles
```

Write down which columns are in Postgres but **completely absent** from Trino's `DESCRIBE`. Those are the unsupported columns being silently dropped.

**Step 2: Identify the actual culprit**

The column that's missing from `DESCRIBE` is the real problem — **not necessarily `plan_tier`**. Check the Postgres table for any of these types:

- `enum` (custom user-defined enums) — should actually work, but if it's missing, another column nearby is the real issue
- `hstore` (key-value type)
- Range types like `int4range`, `tsrange`, `daterange`
- `xml`, `citext`
- Arrays of `timestamp with time zone`
- Geometric types like `POLYGON`

**Step 3: Fix it**

Add this property to your PostgreSQL connector catalog configuration file:

```properties
# etc/catalog/postgresql.properties (or whatever your catalog file is named)
connector.name=postgresql
connection-url=jdbc:postgresql://...
connection-user=${ENV:...}
connection-password=${ENV:...}

postgresql.unsupported-type-handling=CONVERT_TO_VARCHAR
```

Then roll the Trino coordinator and worker pods.

After restart, run `DESCRIBE` again. The previously-missing columns now appear as `VARCHAR` (their Postgres text-cast representation). You lose type safety — every value is a string — but the columns are readable.

**For a one-off test without restarting**, use the session property:

```sql
SET SESSION postgresql.unsupported_type_handling = 'CONVERT_TO_VARCHAR';
-- Now run your SELECT * query in the same session
SELECT * FROM postgresql.public.user_profiles LIMIT 5;
```

### Why `CONVERT_TO_VARCHAR` is the right fix

- **Schema-wide**: it handles all unsupported types in a single setting, not per-column
- **No query changes needed**: your existing `SELECT *` queries just work once you set it
- **Readable**: you get the enum labels as strings, which is usually what you need for joins anyway
- **Trade-off documented**: you're explicitly accepting "this column is VARCHAR, not the original type"

### If you need Postgres-native semantics later

If `CONVERT_TO_VARCHAR` becomes insufficient (e.g., you need to filter ranges with Postgres's `@>` operator), use the `system.query()` escape hatch to push the entire query to Postgres:

```sql
SELECT * FROM TABLE(
  postgresql.system.query(
    query => 'SELECT id, user_email, plan_tier FROM public.user_profiles WHERE plan_tier = ''pro'''
  )
);
```

### Why no error was thrown

Trino is deliberately forgiving. Rather than fail a federation query because of one unmappable column, it assumes you only care about the columns Trino understands and silently drops the rest. This is the opposite of how most SQL databases behave — they error — which is why it's so confusing.
