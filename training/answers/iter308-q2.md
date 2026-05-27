# Answer to Q2: Promoting JSONB Fields from Postgres to Iceberg During Ingestion (Iter 308)

## Why Promoting JSON Fields Matters

Storing event data as a JSON string blob means:
- Trino must re-parse the JSON on **every query** to extract a key like `device_type` — CPU-intensive per row
- **No file-level min/max statistics** for individual JSON keys — `WHERE device_type = 'mobile'` reads every file in the partition range instead of skipping files where no matching rows exist
- A query that should take 1–3 seconds takes 30–45 seconds because it touches 10x more data

Promoting hot fields to typed top-level columns gives you instant extraction, file-level min/max statistics, and dictionary compression — the single biggest analytical performance win available.

## The Two-Tier Pattern: Promoted Columns + Fallback JSON

Don't try to predict all 20 keys upfront. Use:
- **Tier 1 (hot fields):** Promote the top 5–10 keys that appear in dashboard `WHERE` or `GROUP BY` clauses to real `VARCHAR` columns
- **Tier 2 (fallback):** Keep the entire original JSON as `properties_raw VARCHAR` for ad-hoc access to long-tail keys

80% of queries hit known fields and get full columnar benefits. 20% of ad-hoc queries can still extract unpromoted keys on demand without breaking the schema.

## How to Do It: Spark Job (Recommended)

Use `get_json_object` in PySpark to extract fields during ingestion:

```python
from pyspark.sql.functions import get_json_object, col, coalesce

# Read from Postgres via JDBC
df = spark.read.jdbc(
    url="jdbc:postgresql://postgres:5432/myapp",
    table="public.events",
    properties={"user": "spark_user", "password": "...", "fetchsize": "100000"}
)

# Tier 1: extract hot keys as real typed columns
df = (
    df
    .withColumn("plan_name",     get_json_object(col("properties"), "$.plan_name"))
    .withColumn("feature_flag",  get_json_object(col("properties"), "$.feature_flag"))
    .withColumn("device_type",   get_json_object(col("properties"), "$.device_type"))
    .withColumnRenamed("properties", "properties_raw")  # Tier 2: keep original as fallback
)

# Write to Iceberg (with partitioning already defined on the table)
df.writeTo("iceberg.analytics.events").append()
```

**Why `get_json_object` and not `from_json`?** `get_json_object` works when you don't have a full schema — you hand it a key path like `$.device_type` and it returns that value as a string. `from_json` requires defining the entire JSON schema upfront, which is fragile when different event types have different key sets.

## Decision Rule: What to Promote vs Keep in JSON

**Promote a field to top-level column if:**
- It appears in `GROUP BY` or `WHERE` on production dashboards
- It's low-cardinality (~10–10,000 distinct values) — dictionary encoding compresses it nearly to nothing
- You want file-skipping stats for performance

**Keep in `properties_raw` fallback if:**
- Queried only in rare ad-hoc queries (not in dashboards)
- Extremely high-cardinality (per-event IDs, full URLs) — file-skipping won't help anyway
- Schema is volatile (new keys added every week)

## Do You Have to Reprocess Historical Data?

**Yes for full benefits, but it's one-time work.**

Adding a new promoted column to Iceberg is **metadata-only** — instant, no file rewrites. But old Parquet files predate the new column's field ID, so old rows return **NULL** for the new columns. This creates the silent data-loss trap:

```sql
-- DANGEROUS before backfill:
SELECT COUNT(*) FROM iceberg.analytics.events
WHERE device_type = 'mobile';
-- Returns 0 for all historical rows (they have NULL for device_type)
```

**Do the backfill before wiring up dashboards:**

```python
from pyspark.sql.functions import get_json_object, col, coalesce

# Read rows where the promoted column is still NULL (historical rows)
df = spark.read.table("iceberg.analytics.events").filter(col("device_type").isNull())

df_with_extracted = df.withColumn(
    "device_type_new",
    get_json_object(col("properties_raw"), "$.device_type")
)

df_with_extracted.createOrReplaceTempView("events_backfill")

spark.sql("""
    MERGE INTO iceberg.analytics.events t
    USING events_backfill s
      ON t.event_id = s.event_id
    WHEN MATCHED THEN UPDATE SET device_type = s.device_type_new
""")
```

Then verify:
```sql
SELECT COUNT(*) AS still_null
FROM iceberg.analytics.events
WHERE device_type IS NULL
  AND properties_raw LIKE '%device_type%';
-- Should be ~0 after a complete backfill
```

**Backfill time estimate:** A few hours on a large fact table (full scan + MERGE). Schedule during off-peak hours. Only needs to run once per newly promoted column.

## Spark vs dbt

| Approach | Good for |
|---|---|
| **Spark job** | Initial bulk ingest from Postgres, historical backfill, full control over extraction logic |
| **dbt model** | Ongoing transformation logic for recurring pipelines once ingestion is stable |

**Practical recommendation:** Start with a Spark job for the initial ingestion and promotion. Once stable, promote the extraction logic into a dbt model so future tables reuse the same pattern and your team can maintain it without knowing PySpark.

**dbt approach (if already using dbt-trino):**

```sql
-- models/staging/stg_events.sql
SELECT
    event_id,
    tenant_id,
    occurred_at,
    JSON_EXTRACT_SCALAR(properties, '$.plan_name')    AS plan_name,
    JSON_EXTRACT_SCALAR(properties, '$.feature_flag') AS feature_flag,
    JSON_EXTRACT_SCALAR(properties, '$.device_type')  AS device_type,
    properties AS properties_raw
FROM {{ source('postgres', 'events') }}
```

Note: the dbt-trino adapter uses `JSON_EXTRACT_SCALAR` (Trino function) not `get_json_object` (Spark function) — don't mix them up.

## Adding More Promoted Columns Later

When you decide to promote a new key (e.g., `browser_type`) after the initial setup:

```sql
-- Trino: metadata-only, instant
ALTER TABLE iceberg.analytics.events ADD COLUMN browser_type VARCHAR;
```

Then:
1. Update the Spark ingestion job to extract `$.browser_type` for new rows
2. Run the backfill MERGE for historical rows
3. Verify backfill completeness
4. Wire dashboards to the new column

The schema change is free. The backfill is the one-time cost each time.

## Summary

1. **Promote 5–10 hot keys** using `get_json_object(col("properties"), "$.key")` in PySpark
2. **Keep the original JSON** as `properties_raw VARCHAR` for long-tail ad-hoc access
3. **Historical backfill is required** before pointing queries at new promoted columns — use MERGE INTO
4. **Use Spark for initial ingest; dbt for ongoing pipeline maintenance**
5. **Future promotions** are metadata-only schema changes in Iceberg + a one-time backfill MERGE

The promotion cost is paid once. The file-skipping benefit applies to every dashboard query forever.
