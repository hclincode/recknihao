# Iter 193 Q1 — Postgres Type Mapping: JSONB, UUID, NUMERIC, and Unsupported Types

## Answer

I'll address each of your concerns directly, using Trino's specific behavior with PostgreSQL types.

### Type Mapping: UUID, NUMERIC, and JSONB

**Good news on UUID and NUMERIC(10,2)**: These types come through correctly. According to the resources:

- **UUID**: Maps cleanly from Postgres `uuid` to Trino's `UUID` type. The connector handles this mapping automatically.
- **NUMERIC(10,2)**: Maps to Trino's numeric types with precision preserved. You'll be able to query and aggregate these invoice amounts without loss of precision.

**JSONB is the tricky one**: Postgres `jsonb` does NOT map to Trino's native JSON type. Instead, the PostgreSQL connector maps `jsonb` columns to Trino `VARCHAR` — meaning Trino receives them as strings, not structured JSON objects.

### Filtering on JSONB: Limitations and Workarounds

This is the critical limitation you should know about:

**You cannot push JSONB filtering predicates down to Postgres.** Here's why: Trino sees the JSONB column as a string, so when you try to filter using Postgres's JSONB operators (`?` "contains key", `@>` "contains", etc.), Trino doesn't understand them and cannot send those predicates to Postgres for server-side execution. The string stays opaque to Trino's planner.

**What you CAN do** (with caveats):

1. **Use Trino's JSON string functions on the VARCHAR**: You can read the JSONB as a string and extract fields using `json_extract_scalar()` or other Trino JSON functions:
   ```sql
   SELECT id, json_extract_scalar(metadata, '$.event_type') as event_type
   FROM <catalog>.<schema>.<table>
   WHERE json_extract_scalar(metadata, '$.event_type') = 'user_login'
   ```
   However, this filtering happens **after Trino fetches the entire column** — the predicate does NOT push down to Postgres, so you pull all rows across the network and filter locally. For a table with 10 million rows and a selective JSONB filter, this becomes a serious performance problem.

2. **Use Postgres's native JSONB operators via `system.query()`**: If you need to leverage Postgres's JSONB operators (which are much more efficient), use the escape hatch — the PostgreSQL connector exposes a `system.query()` table function that sends raw SQL directly to Postgres:
   ```sql
   SELECT * FROM TABLE(app_pg.system.query(
       query => 'SELECT id, metadata FROM public.events 
                 WHERE metadata ? ''event_type'''
   ));
   ```
   This executes the filtering in Postgres, then returns the result set to Trino. The filtering is server-side, which is what you want for performance.

3. **Restructure at ingestion time**: For heavy JSONB analytics workloads, the best long-term solution is to denormalize: ingest those Postgres tables into your Iceberg lakehouse (via Spark/Iceberg) and explode the JSON into explicit columns. Then your analysts query the Iceberg tables directly with all predicates pushing down correctly. This is the recommended pattern when JSONB filtering is a frequent bottleneck.

### Unsupported Types: Column Skip, Not Table Skip

Good news: **A single unsupported type does NOT make the entire table unavailable.** The behavior is controlled by the `unsupported_type_handling` catalog property:

- **Default (`IGNORE`)**: Trino skips the column entirely. You can still query the rest of the table's columns. That problematic column is simply not visible to Trino.
- **`CONVERT_TO_VARCHAR`**: Trino reads the unsupported type as a string. This is useful if you know a column's type isn't natively supported but you still want to read it.

Example configuration (in your Trino catalog properties):
```
<catalog>.unsupported_type_handling = CONVERT_TO_VARCHAR
```

So if Postgres has a custom geometric type (`polygon`, for example) that Trino doesn't understand, you can either skip it (`IGNORE`, the default) or read it as a string (`CONVERT_TO_VARCHAR`). Either way, your other columns remain queryable.

### Summary for Your Workflow

| Type | Maps correctly? | Filtering behavior | Recommendation |
|---|---|---|---|
| UUID | Yes, to Trino UUID | Pushes down `WHERE tenant_id = UUID '...'` | Cast literals to UUID type; pushdown works |
| NUMERIC(10,2) | Yes, with precision | Pushes down numeric comparisons | Works as expected |
| JSONB | No — maps to VARCHAR | Does NOT push down JSONB operators | Use `system.query()` for Postgres JSONB operators, or ingest to Iceberg with exploded columns for analytics |
| Other unsupported types | Configurable | N/A | Default skips column; use `CONVERT_TO_VARCHAR` to read as string |
