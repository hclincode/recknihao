# Iter96 Q2 — Answer

**Question**: We are streaming changes from our Postgres database into Iceberg using CDC (we use Debezium). Most of our columns are straightforward — integers, timestamps, strings. But we have a few columns that are Postgres JSONB, where each row can have a different set of keys. When those JSONB columns come through Debezium, what actually lands in the Iceberg table — does it arrive as a raw string, or does Iceberg try to expand it into separate columns? And what happens to our Iceberg table if a developer adds a new key to that JSONB column in Postgres — does anything break downstream, or does the pipeline handle it automatically?

---

## Answer

## What lands in Iceberg: a raw VARCHAR string

Debezium treats Postgres JSONB as an opaque string. It arrives in your Iceberg table as a **VARCHAR column containing the raw JSON text**. Parquet (the file format underlying Iceberg) has no native JSON type — no automatic expansion into separate columns happens. For example:

```
event_id | properties (VARCHAR)
---------|-----------------------------------------------
42       | {"device_type":"mobile","plan":"pro","country":"US"}
43       | {"device_type":"desktop","referrer":"google"}
```

You can query keys in Trino using `json_extract_scalar()`:

```sql
SELECT json_extract_scalar(properties, '$.device_type'), COUNT(*)
FROM iceberg.analytics.events
GROUP BY 1;
```

**But this is slow.** Trino must parse the JSON string on every query, and you lose Parquet's columnar compression and partition pruning. A filter on `device_type` scans the entire `properties` column even when everything else could be skipped.

## The recommended approach: flatten hot keys at ingest time

Your Spark job (reading from Debezium/Kafka and writing to Iceberg) should extract the most-queried JSON keys into real columns **before writing**. Keep the original blob as a fallback:

```python
from pyspark.sql.functions import get_json_object

df = (df
    .withColumn("device_type",   get_json_object("properties", "$.device_type"))
    .withColumn("plan_at_event", get_json_object("properties", "$.plan_at_event"))
    .withColumn("country",       get_json_object("properties", "$.country"))
    .withColumnRenamed("properties", "properties_raw")  # keep original blob
)
```

The Iceberg table becomes:

```
event_id | device_type | plan_at_event | country | properties_raw (VARCHAR)
---------|-------------|---------------|---------|-----------------------------------
42       | mobile      | pro           | US      | {"device_type":"mobile","plan":"pro","country":"US"}
43       | desktop     | NULL          | NULL    | {"device_type":"desktop","referrer":"google"}
```

Now Trino queries are fast:

```sql
SELECT device_type, COUNT(*)
FROM iceberg.analytics.events
WHERE plan_at_event = 'enterprise'
GROUP BY 1;
```

Parquet can use columnar pruning and dictionary compression on the promoted columns. Old rows return NULL for keys that didn't exist — no backfill needed.

## What happens when a developer adds a new JSONB key in Postgres

**The pipeline keeps running — nothing breaks.**

Debezium's PostgresConnector sees the JSONB column as a single `json` type in the WAL. It does not parse the JSON to detect new keys. A developer can add a new key like `session_id` and Debezium captures it as-is: the full JSON string flows into Kafka, your Spark job reads it, and it lands in `properties_raw` VARCHAR column in Iceberg. The schema does not change, no errors occur.

To query the new key before promoting it:
```sql
SELECT json_extract_scalar(properties_raw, '$.session_id'), COUNT(*)
FROM iceberg.analytics.events
GROUP BY 1;
```

## How to promote a new key to a real column

When a new key becomes important enough for fast queries, update your Spark job and evolve the Iceberg schema:

**If you use incremental append** (`writeTo(...).append()`):

```sql
-- Run this once (metadata-only, milliseconds even on large tables)
ALTER TABLE iceberg.analytics.events ADD COLUMN session_id VARCHAR;
```

Then update the Spark job:
```python
df = df.withColumn("session_id", get_json_object("properties", "$.session_id"))
```

New rows get the real value. Old rows automatically return NULL for the new column — Iceberg's schema evolution guarantee, no backfill required.

**If you use full-refresh** (`writeTo(...).createOrReplace()`):

Do NOT run ALTER TABLE separately. Just update the Spark job's column list — the next run rebuilds the table from the DataFrame schema.

## Rule of thumb

- **Flatten anything you `GROUP BY`, `WHERE`, or `JOIN ON`** — those become real columns.
- **Leave everything else in `properties_raw`** — the long tail of one-off keys stays in the JSON blob for flexibility.

This keeps your Iceberg schema stable. When new JSONB keys appear in Postgres, the pipeline never breaks — they land in the fallback column until you decide they need their own column.
