# Iter111 Q1 — Answer

**Question**: We're using Debezium to stream changes from Postgres into our Iceberg tables. It's working fine for INSERTs and UPDATEs, but I'm running into a weird problem: some of our Postgres tables use JSONB columns to store flexible per-customer settings, and those show up in Iceberg in a way that makes them really hard to query. Right now the whole JSONB blob just lands as a single string column, so if I want to filter on a nested field like `settings->>'plan_tier'`, I can't do it efficiently — Trino has to scan every row and parse the string. Is there a standard way to handle this? Should we be flattening those JSONB fields during ingestion somehow, or is there a better pattern?

---

## Answer

You've identified the core issue: **Parquet (which Iceberg uses under the hood) has no native JSON type**, so your JSONB columns must be handled at ingest time, not deferred to query time. There are two options; the second is the production standard.

### Option 1: Store as VARCHAR, parse at query time (simplest, but slow)

Write the entire JSONB blob as a string column in Iceberg. Query it on-the-fly:

```sql
SELECT json_extract_scalar(properties, '$.plan_tier'), COUNT(*)
FROM iceberg.analytics.events
GROUP BY 1;

-- Or filter:
SELECT *
FROM iceberg.analytics.events
WHERE json_extract_scalar(properties, '$.plan_tier') = 'enterprise';
```

**Pros:** Lossless, schema-flexible, no pipeline changes.
**Cons:** Trino re-parses the JSON string on every query. Your `plan_tier` filter requires a full table scan with runtime parsing — exactly the inefficiency you're already experiencing.

### Option 2: Flatten hot fields into real columns (recommended)

Extract the top 5–10 most-queried JSON keys into typed columns during Spark ingestion. Keep the original blob as a VARCHAR fallback:

```python
from pyspark.sql.functions import get_json_object, current_timestamp

# After reading from Postgres via JDBC or Debezium events:
df = (df
    .withColumn("plan_tier",   get_json_object("properties", "$.plan_tier"))
    .withColumn("device_type", get_json_object("properties", "$.device_type"))
    .withColumn("region",      get_json_object("properties", "$.region"))
    .withColumnRenamed("properties", "properties_raw")
    .withColumn("batch_loaded_at", current_timestamp()))

# Write to Iceberg:
df.writeTo("iceberg.analytics.events").append()
```

Your Iceberg table now has real columns `plan_tier VARCHAR`, `device_type VARCHAR`, `region VARCHAR`. The original blob lives in `properties_raw VARCHAR` for the long tail of rarely-accessed keys.

**Query becomes fast:**

```sql
WHERE plan_tier = 'enterprise'  -- columnar, no parsing, Parquet predicate pushdown
AND region = 'us-east-1'        -- columnar, no parsing
```

For ad-hoc access to unflatted keys:
```sql
WHERE json_extract_scalar(properties_raw, '$.some_rare_field') = 'value'
```

### The rule of thumb

**Flatten anything you `GROUP BY`, `WHERE`, or `JOIN ON`. Leave everything else in the fallback `properties_raw` VARCHAR.**

### When the app adds a new JSON key

- **Pipeline level**: No breakage — `properties_raw` VARCHAR still captures the full blob including new keys.
- **If you need to filter on the new key**: Update the Spark job to extract it, then run:
  ```sql
  ALTER TABLE iceberg.analytics.events ADD COLUMN plan_features VARCHAR;
  ```
  This is metadata-only in Iceberg — no data rewrite. Old rows return NULL for the new column automatically. New rows have the real value. No backfill needed unless you specifically want historical values populated.

### You don't need to change your Debezium setup

Debezium streams the full row (including the JSONB blob as a string) to Kafka/Spark. The flattening happens in your Spark transformation step — Debezium is unaware of it. No connector configuration changes required.

### What NOT to do

Don't store JSONB as Iceberg `MAP<STRING,STRING>` or as a `STRUCT` with one field per key. Both make schema evolution worse, not better — they're tempting but operationally painful.
