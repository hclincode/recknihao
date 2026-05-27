# Answer to Q2: Handling JSONB Columns from Postgres in Iceberg

## The two options

You have two solid options for handling JSONB columns in your Postgres-to-Iceberg pipeline. The right choice depends on whether the JSON schema is predictable.

---

## Option 1: Store as VARCHAR (raw JSON string)

Write the JSONB blob as-is into Iceberg as a `VARCHAR` column, then parse it at query time using Trino's JSON functions.

**Spark ingest:**
```python
from pyspark.sql.functions import col

df = df.withColumnRenamed("event_payload", "event_payload_raw")
df.writeTo("iceberg.analytics.webhook_events").append()
```

**Querying from Trino:**
```sql
SELECT
    event_id,
    json_extract_scalar(event_payload_raw, '$.user.id') AS user_id,
    json_extract_scalar(event_payload_raw, '$.action') AS action,
    COUNT(*)
FROM iceberg.analytics.webhook_events
GROUP BY 1, 2, 3;
```

**Trade-offs:**
- **Pro:** Dead simple at ingest, schema-flexible (new keys appear automatically), lossless.
- **Con:** Slow — Trino re-parses the JSON string on every query, row-by-row.
- **Critical limitation — no file skipping:** `WHERE json_extract_scalar(event_payload_raw, '$.plan') = 'enterprise'` cannot use Parquet per-file min/max stats. Trino reads every file in the partition range. For large tables, a query that should take seconds takes minutes.

**Type safety note:** `json_extract_scalar` always returns VARCHAR. If you need numeric comparison, cast explicitly:
```sql
CAST(json_extract_scalar(event_payload_raw, '$.score') AS DECIMAL) > 100
```
Without the cast, you get lexicographic comparison where `'99' > '100'` evaluates as true.

---

## Option 2: Flatten hot fields into typed columns (Recommended for known schema)

Extract the 5–10 most-queried keys into real typed columns at ingest time. Keep the original JSON as a `_raw VARCHAR` fallback for everything else.

**Spark ingest:**
```python
from pyspark.sql.functions import col, get_json_object, from_json
from pyspark.sql.types import ArrayType, StringType

df = (df
    .withColumn("user_id",       get_json_object("event_payload", "$.user.id"))
    .withColumn("action",        get_json_object("event_payload", "$.action"))
    .withColumn("action_result", get_json_object("event_payload", "$.result"))
    # Keep the full original blob for unpromoted fields
    .withColumnRenamed("event_payload", "event_payload_raw")
)

df.writeTo("iceberg.analytics.webhook_events").append()
```

**Querying promoted fields from Trino:**
```sql
SELECT event_id, user_id, action, COUNT(*)
FROM iceberg.analytics.webhook_events
WHERE action = 'purchase'
  AND occurred_at >= CURRENT_DATE - INTERVAL '7' DAY
GROUP BY 1, 2, 3;
```

`action = 'purchase'` on a promoted column lets Trino use per-file min/max stats and skip files that can't contain `'purchase'`. The same predicate on the raw JSON string cannot skip any files.

**Querying unpromoted fields (still possible):**
```sql
SELECT event_id,
       json_extract_scalar(event_payload_raw, '$.custom_field') AS custom_field
FROM iceberg.analytics.webhook_events
WHERE user_id = 'user_123';
```

**Handling nested arrays:**
```python
tags_schema = ArrayType(StringType())
df = df.withColumn(
    "tags_array",
    from_json(get_json_object("event_payload", "$.tags"), tags_schema)
)
```
```sql
-- In Trino:
SELECT * FROM events WHERE contains(tags_array, 'premium');
```

---

## The file-skipping advantage — why flattening matters

This is the single biggest reason to flatten hot keys:

- `json_extract_scalar(event_payload_raw, '$.action') = 'purchase'` → Trino reads every file in the partition range. No file-level pruning — Parquet statistics can't see inside a JSON string.
- `action = 'purchase'` (promoted column) → Trino uses per-file min/max. Files whose action range excludes `'purchase'` are skipped in milliseconds. For low-cardinality enums, this typically skips 80–95% of files.

Flattening 5–10 hot keys is often the difference between a 45-second query and a 2-second query at scale.

---

## Decision table for your two use cases

| Column | Characteristics | Recommendation |
|---|---|---|
| `event_payload` (webhook events) | Mostly known shape: user, action, result, timestamp; new keys occasionally appear | **Flatten** the hot keys (`user_id`, `action`, `action_result`) to top-level columns. Keep `event_payload_raw VARCHAR` as fallback for the long tail. |
| `metadata` (customer-defined attributes) | Truly variable per customer; no consistent schema | **Store as `metadata_raw VARCHAR`**. Customers set their own keys; flattening is impossible. Accept that JSON-function queries are slower — metadata is typically used for single-row lookups, not high-cardinality aggregations. |

---

## Schema evolution when you promote a new field

When you decide a previously-unpromoted key is now queried heavily enough to promote:

1. `ALTER TABLE iceberg.analytics.webhook_events ADD COLUMN custom_field VARCHAR;`
   — Metadata-only, instant, no file rewrites. Old rows return NULL for the new column.
2. New rows get the real value immediately.
3. Optional backfill: run a Spark MERGE INTO that reads `custom_field` from `event_payload_raw` for old rows, if you need historical non-NULL values.

---

## Complete minimal ingestion example

```python
from pyspark.sql.functions import get_json_object, current_timestamp
from pyspark.sql import SparkSession

spark = SparkSession.builder \
    .config("spark.sql.catalog.iceberg", "org.apache.iceberg.spark.SparkCatalog") \
    .config("spark.sql.catalog.iceberg.type", "hive") \
    .config("spark.sql.catalog.iceberg.uri", "thrift://hive-metastore:9083") \
    .config("spark.sql.catalog.iceberg.warehouse", "s3a://lakehouse/warehouse") \
    .getOrCreate()

df = spark.read.format("jdbc") \
    .option("url", "jdbc:postgresql://postgres:5432/app") \
    .option("dbtable", "webhook_events") \
    .option("user", "spark_user") \
    .option("password", "password") \
    .option("partitionColumn", "id") \
    .option("lowerBound", 1) \
    .option("upperBound", 1000000) \
    .option("numPartitions", 16) \
    .load()

df = (df
    .withColumn("user_id",       get_json_object("event_payload", "$.user.id"))
    .withColumn("action",        get_json_object("event_payload", "$.action"))
    .withColumn("action_result", get_json_object("event_payload", "$.result"))
    .withColumnRenamed("event_payload", "event_payload_raw")
    .withColumnRenamed("metadata",      "metadata_raw")
    .withColumn("ingested_at", current_timestamp())
)

df.writeTo("iceberg.analytics.webhook_events").append()
```

---

## Summary

- **Known schema → flatten hot fields** to typed columns. File skipping makes these queries 10–50x faster than JSON parsing. Keep the raw blob as a fallback.
- **Variable schema → store as VARCHAR**. Accept slower query performance. Use `json_extract_scalar` for ad-hoc access.
- Your `event_payload` (webhook events with a mostly-known shape) → flatten. Your `metadata` (customer-defined, no stable schema) → store raw.
- New promoted columns are a metadata-only `ALTER TABLE ADD COLUMN` — cheap and safe to do at any time.
