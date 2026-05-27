# Iter48 Q2 Answer — JSONB column handling in Iceberg/Trino

**Question**: We have a Postgres `events` table with a `properties` JSONB column that stores per-event metadata like `{"device_type": "mobile", "os_version": "17.4", "session_id": "abc123"}`. After we ingested the table into Iceberg using Spark JDBC, the `properties` column shows up as `STRING` in Iceberg — not as a structured column I can do `properties.device_type` on. In Postgres I can do `properties->>'device_type'` and get the value out. How do I query the `device_type` out of the `properties` column in Trino, and separately, is there a way to make Iceberg store it as a proper struct instead of a string so I can use dot notation?

---

## Why it's stored as STRING

Postgres JSONB is a binary JSON type with rich query operators (`->`, `->>`). When Spark reads it via JDBC, the JDBC driver converts it to a plain `VARCHAR` string — because Parquet (the file format Iceberg uses) has no native JSON type. Everything is stored as the raw JSON text: `{"device_type": "mobile", "os_version": "17.4", "session_id": "abc123"}`. Iceberg sees STRING; the structure is gone at the storage layer.

## How to query `device_type` right now in Trino

Use Trino's `json_extract_scalar()` — it's the direct equivalent of Postgres `properties->>'device_type'`:

```sql
SELECT
  json_extract_scalar(properties, '$.device_type') AS device_type,
  json_extract_scalar(properties, '$.os_version') AS os_version,
  COUNT(*) AS event_count
FROM iceberg.analytics.events
WHERE json_extract_scalar(properties, '$.device_type') = 'mobile'
GROUP BY 1, 2;
```

This works immediately without any schema changes. The downside: Trino re-parses the entire JSON string on every query for every row. On large tables (billions of events), the parsing overhead adds up significantly. It's acceptable for occasional ad-hoc exploration but too slow for production dashboards.

## The right fix: flatten at ingest time in Spark

You can't retrofit a STRING into a struct after the fact without rewriting the entire table. The right approach is to extract the JSON keys you query frequently into real Iceberg columns **at ingestion time in Spark**, before the data hits Iceberg:

```python
from pyspark.sql.functions import get_json_object

df = spark.read.jdbc(url=PG_URL, table="public.events", properties=PG_PROPS)

# Extract the hot keys into real typed columns
df = (df
    .withColumn("device_type", get_json_object("properties", "$.device_type"))
    .withColumn("os_version",  get_json_object("properties", "$.os_version"))
    .withColumn("session_id",  get_json_object("properties", "$.session_id"))
    .withColumnRenamed("properties", "properties_raw")  # keep the original as fallback
)

df.writeTo("iceberg.analytics.events").append()
```

Your Iceberg table schema becomes:

```sql
CREATE TABLE iceberg.analytics.events (
    event_id        STRING,
    occurred_at     TIMESTAMP,
    device_type     STRING,      -- real column, not JSON
    os_version      STRING,
    session_id      STRING,
    properties_raw  VARCHAR,     -- original JSON blob for long-tail queries
    ...
)
```

Now Trino queries are plain column references — no JSON parsing:

```sql
SELECT device_type, COUNT(*)
FROM iceberg.analytics.events
WHERE device_type = 'mobile'
GROUP BY device_type;
```

**Why this is significantly faster:**
- Trino reads only the `device_type` column from Parquet — no full JSON blob reads
- Iceberg's min/max file statistics work on `device_type`, so queries with a WHERE filter skip entire files
- Low-cardinality columns like `device_type` compress to nearly nothing in Parquet's dictionary encoding

## Adding new JSON keys later — no rewrite needed

Say your product adds `"variant_group": "experiment_42"` to events next month:

1. Update the Spark job: `.withColumn("variant_group", get_json_object("properties", "$.variant_group"))`
2. Add the column in Trino: `ALTER TABLE iceberg.analytics.events ADD COLUMN variant_group VARCHAR;`
   - This is metadata-only — instant, even on terabytes of existing data
3. Re-run the Spark ingestion job

New events get the real value. Historical events return NULL automatically — Iceberg handles this with no Parquet rewrite of old data. If analysts need backfilled values for old events, that's a separate one-time Spark job using `overwritePartitions()`.

## The rule of thumb

**Flatten anything you query frequently** — anything in `WHERE`, `GROUP BY`, or `JOIN ON` across multiple dashboards, typically 5–10 hot keys. Keep everything else in `properties_raw` as a VARCHAR fallback. This balances:
- **Speed** — no JSON parsing at query time for common queries
- **Flexibility** — `properties_raw` still has the full JSON for unexpected ad-hoc questions

Why not use Iceberg struct type instead of separate columns? Structs require defining the schema upfront and are harder to evolve. The column-flattening approach lets you add columns incrementally as you discover hot keys, old rows get NULL automatically (no rewrite), and Trino queries stay simple — no nested type syntax.
