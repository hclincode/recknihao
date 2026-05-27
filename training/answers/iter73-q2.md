# Iter73 Q2 — Answer

**Question**: We have a Postgres table with a JSONB column — per-customer config with different structure for each customer, some nested two or three levels deep, others flat. We're syncing this to Iceberg. If we cast it to a string, the data is there but useless for filtering. We can't flatten it because the schema varies per customer. Does Iceberg support nested column types? Or is string the only real option, and if so, are there tricks to make it queryable in Trino?

---

## Answer

**TL;DR:** Store it as VARCHAR (string), but don't stop there. Extract your 5–10 most-queried JSON keys into real columns at ingest time, and keep the full JSON blob as a fallback column. This gives you fast queries on the common cases and full flexibility for the long tail.

### Why not use Iceberg nested types (STRUCT, MAP, ARRAY)?

Iceberg does support nested types. You could technically store a nested structure like:

```sql
CREATE TABLE customer_config (
  customer_id VARCHAR,
  config STRUCT<type VARCHAR, settings STRUCT<enabled ARRAY<VARCHAR>, tier VARCHAR>>
)
```

But this doesn't work for your situation because:

1. **Schema rigidity**: The STRUCT type is table-wide. If customer A has `settings.tier` but customer B has `settings.plan_name`, there's no single STRUCT definition that fits both. Every customer would need to conform to the same shape.
2. **Query complexity**: Accessing nested fields requires type casting and exact path matching. Missing paths return NULL but require knowing the full schema upfront.
3. **Parquet performance**: Deeply nested STRUCT columns mean Trino reads entire nested blocks to access one inner field, negating the columnar benefit.

For per-customer schemas with varying structure, **VARCHAR + selective flattening is the right design**.

### The recommended approach: selective flattening + raw blob

At ingest time in Spark, extract the keys you query most frequently into real columns, and keep the full JSON as a VARCHAR:

```python
from pyspark.sql.functions import get_json_object

df = (df
    .withColumn("config_type",       get_json_object("jsonb_col", "$.config_type"))
    .withColumn("tier_level",        get_json_object("jsonb_col", "$.tier_level"))
    .withColumn("enabled_features",  get_json_object("jsonb_col", "$.enabled_features"))
    .withColumnRenamed("jsonb_col", "config_raw")  # keep original blob
)

df.writeTo("iceberg.analytics.customer_config").append()
```

The resulting Iceberg table has:
- `config_type VARCHAR` — real column, fast
- `tier_level VARCHAR` — real column, fast
- `enabled_features VARCHAR` — real column, fast
- `config_raw VARCHAR` — the full JSON blob, queryable but slower

### Querying the flattened columns (fast path)

```sql
-- Fast: uses Parquet min/max statistics and dictionary compression
SELECT config_type, COUNT(*)
FROM iceberg.analytics.customer_config
WHERE tier_level = 'enterprise'
GROUP BY config_type;
```

This is fast because:
- Parquet's min/max statistics skip entire files where `tier_level` has no matching values
- Dictionary compression makes the column tiny (likely 5–20 distinct values)
- Trino reads only the needed columns from disk, not the full row

### Querying the raw JSON (flexible path)

For keys not in the flattened columns, use Trino's `json_extract_scalar`:

```sql
-- Slower: Trino re-parses the JSON string on every row
SELECT json_extract_scalar(config_raw, '$.some_niche_setting'), COUNT(*)
FROM iceberg.analytics.customer_config
WHERE config_type = 'type_a'
GROUP BY 1;
```

This is correct and fine for ad-hoc queries. If you find yourself running the same extraction frequently, that's the signal to promote the key to a real column.

### Handling nested and array values

`get_json_object` works on nested paths and array indices:

```python
# Nested path
df = df.withColumn("nested_val", get_json_object("jsonb_col", "$.config.nested.value"))

# Array element by index
df = df.withColumn("first_tag", get_json_object("jsonb_col", "$.tags[0]"))
```

For array membership checks (e.g., "does this customer have the `enterprise` tag?"), parse the array:

```python
from pyspark.sql.functions import from_json, array_contains
from pyspark.sql.types import ArrayType, StringType

tags_schema = ArrayType(StringType())
df = (df
    .withColumn("tags_array", from_json(get_json_object("jsonb_col", "$.tags"), tags_schema))
    .withColumn("has_enterprise", array_contains(col("tags_array"), "enterprise"))
)
```

Now `WHERE has_enterprise = true` is a real column filter — fast.

### Adding new flattened columns over time

When you discover a previously-long-tail key is now frequently queried:

1. Update your Spark ingest job to extract it: `df = df.withColumn("new_key", get_json_object(...))`
2. Run `ALTER TABLE iceberg.analytics.customer_config ADD COLUMN new_key VARCHAR` (metadata-only, takes milliseconds)
3. New ingestion runs populate the real column. Old rows return NULL for the new column automatically — Iceberg handles this backward-compatibly.

No historical reload needed.

### Decision checklist — what to flatten vs keep as JSON

| Usage pattern | Decision |
|---|---|
| Filtered in WHERE clauses | Flatten to real column |
| Used in GROUP BY aggregations | Flatten to real column |
| Used in dashboard filters | Flatten to real column |
| Appears in < 20% of rows | Keep in raw JSON |
| Never queried directly | Keep in raw JSON |
| Queried occasionally, ad-hoc | Keep in raw JSON; use `json_extract_scalar` |

Start with 5 columns. Expand when query patterns stabilize. The raw blob always gives you a fallback.

### Summary

| Option | Fast queries | Handles variable schema | Trino-queryable |
|---|---|---|---|
| Store as VARCHAR (raw only) | No | Yes | Yes, with `json_extract_scalar` |
| Flatten to STRUCT | Yes | No — requires fixed schema | Yes |
| Selective flatten + raw blob (recommended) | Yes for hot keys | Yes for long tail | Yes for both |

Iceberg's schema evolution means you pay no penalty for adding new flattened columns later. Start lean (5 columns + raw blob), then promote keys to real columns as your query patterns emerge.
