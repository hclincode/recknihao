# Iter247 Q1 — JSONB Columns in Trino PostgreSQL Federation

## Answer

Good news: **JSONB is supported** — but there's a specific limitation you've hit.

### What's Happening

Trino's PostgreSQL connector maps Postgres `JSONB` columns to Trino's `JSON` type. This mapping works fine, and you can read JSONB columns without an explicit cast. The error you're seeing is likely one of two things:

1. **Your setup treats JSONB as an unsupported type** — older configurations or specific connector settings may silently drop the column or throw an error.
2. **You're hitting a type-mapping edge case** where the connector encountered something it doesn't recognize.

**Diagnose first:**

```sql
DESCRIBE app_pg.public.settings_table;
```

Look at what type Trino reports for your settings column. It should say `JSON`. If it shows something unexpected, that's your clue.

Also try:

```sql
SHOW COLUMNS FROM app_pg.public.settings_table;
```

### If the Column Vanishes or Errors Out: Two Workarounds

**Option 1: Exclude the JSONB column from SELECT * and reference it explicitly**

```sql
SELECT id, name, json_extract_scalar(settings, '$.key_name') AS some_config
FROM app_pg.public.settings_table
WHERE id = 123;
```

Trino's JSON functions (`json_extract_scalar()`, `json_extract()`) work on JSONB-mapped columns once Trino sees them as `JSON` type.

**Option 2: Use `system.query()` to run Postgres-native JSONB operations server-side**

If you need to filter by JSONB content or use Postgres-specific JSONB operators (`?`, `@>`, `->>`), use the escape hatch — this sends the query directly to Postgres:

```sql
SELECT * FROM TABLE(
  app_pg.system.query(
    query => 'SELECT id, name, settings FROM public.settings_table WHERE settings ? ''some_key'''
  )
);
```

This runs on Postgres itself, so it can use JSONB indexes and native operators. The entire query executes on Postgres, not on Trino workers.

### The Permanent Fix (If You Use JSONB Heavily for Analytics)

If you're querying these settings frequently for analytics, **ingest the Postgres table into Iceberg** using Spark and **denormalize the JSONB into explicit columns** (e.g., `customer_id`, `plan_tier`, `max_seats` as separate columns instead of nested inside `settings`). This gives you:
- No JSONB type quirks — everything is a standard column
- Fast, columnar scans instead of row-by-row JDBC reads
- Partition pruning and file skipping (Iceberg's built-in optimizations)

For occasional config lookups: `system.query()` is fine. For analytics workloads: denormalized Iceberg is the right long-term move.
