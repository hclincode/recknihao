# Iter60 Q2 — Answer

**Question**: We're ingesting data from Postgres into Iceberg using JDBC. Most of our columns are straightforward — ints, timestamps, varchars — and those land in Iceberg cleanly. But we have one table that stores user event metadata in a `JSONB` column, and that column can have 10-15 different keys depending on the event type. When we pull it over JDBC it comes through as a raw string. We want to be able to filter and aggregate on those nested fields in Trino — like `WHERE metadata->>'plan' = 'pro'` — but we can't do that on a plain string column efficiently. What's the right way to handle this? Should we be flattening those JSON fields into separate columns during ingestion, or is there a way to query into the string with Trino?

---

## Answer

The short answer: **flatten the keys you query frequently into real columns at ingest time, and keep the raw JSON as a fallback column for the long tail.** Querying JSON strings in Trino with `json_extract_scalar()` works, but it's always a full-scan — Trino can't apply predicate pushdown or column statistics to a VARCHAR blob. Flattened typed columns get min/max stats and predicate pruning for free.

### How JSONB lands when ingested via JDBC

Postgres JSONB is not a recognized JDBC type. When Spark reads it via JDBC, it comes through as a `StringType` column — the raw JSON text as a string. Iceberg stores it as a `VARCHAR`. The structure is preserved, but it's opaque to the query engine.

```
Postgres: metadata JSONB = {"plan": "pro", "device_type": "mobile", "feature_name": "export"}
Iceberg:  metadata VARCHAR = '{"plan":"pro","device_type":"mobile","feature_name":"export"}'
```

### Option A: query the raw string with Trino JSON functions

Trino has `json_extract_scalar()` for extracting fields from a JSON string:

```sql
-- Works, but always does a full scan
SELECT COUNT(*)
FROM iceberg.analytics.events
WHERE json_extract_scalar(metadata, '$.plan') = 'pro';
```

This reads every row, parses the JSON, extracts the field, and applies the filter. No file pruning, no column statistics, no pushdown. At small scale this is fine. At tens of millions of rows across years of history, every `WHERE` on a JSON field becomes an expensive full-scan.

Trino also supports `JSON_VALUE` (SQL/JSON syntax):

```sql
SELECT JSON_VALUE(metadata, 'lax $.plan')
FROM iceberg.analytics.events;
```

Both work. Neither gets predicate pushdown.

### Option B (recommended): flatten hot keys at ingest time

In your Spark JDBC ingestion job, extract the 5–10 most-queried keys from the JSON and write them as real typed columns. Keep the full JSON in a `metadata_raw` column for rare or unknown keys.

```python
from pyspark.sql.functions import get_json_object

# Read from Postgres via JDBC
df = spark.read.jdbc(url=PG_URL, table="public.events", properties=PG_PROPS)

# Extract hot keys into real columns
df = (df
    .withColumn("plan",         get_json_object("metadata", "$.plan"))
    .withColumn("device_type",  get_json_object("metadata", "$.device_type"))
    .withColumn("feature_name", get_json_object("metadata", "$.feature_name"))
    .withColumnRenamed("metadata", "metadata_raw")  # keep the blob
)

# Write to Iceberg
df.writeTo("iceberg.analytics.events").using("iceberg").createOrReplace()
```

Your Iceberg table schema becomes:

```sql
CREATE TABLE iceberg.analytics.events (
    event_id      VARCHAR,
    occurred_at   TIMESTAMP(6) WITH TIME ZONE,
    plan          VARCHAR,        -- extracted from JSON at ingest
    device_type   VARCHAR,        -- extracted from JSON at ingest
    feature_name  VARCHAR,        -- extracted from JSON at ingest
    metadata_raw  VARCHAR         -- original JSON, for ad-hoc long-tail queries
)
WITH (
    format = 'PARQUET',
    partitioning = ARRAY['day(occurred_at)']
);
```

Now your Trino queries on common fields are just column filters — fast, with statistics:

```sql
-- Fast: plan is a real column, Parquet min/max stats apply
SELECT plan, COUNT(*)
FROM iceberg.analytics.events
WHERE plan = 'pro'
GROUP BY plan;
```

For rare keys, fall back to `json_extract_scalar()` on `metadata_raw`:

```sql
-- Slower (no pushdown), but only for ad-hoc one-off queries
SELECT json_extract_scalar(metadata_raw, '$.session_id'), COUNT(*)
FROM iceberg.analytics.events
WHERE plan = 'pro'       -- fast column filter narrows the scan first
GROUP BY 1;
```

### Option C: parse JSON into a MAP column in Spark

If you have too many keys to list explicitly, Spark's `from_json()` can parse the JSON into a `MapType(StringType, StringType)` — stored in Iceberg as a native MAP column. Trino can query it with bracket syntax:

```python
from pyspark.sql.functions import from_json
from pyspark.sql.types import MapType, StringType

schema = MapType(StringType(), StringType())
df = df.withColumn("metadata_map", from_json("metadata", schema))
```

In Trino:

```sql
SELECT metadata_map['plan'], COUNT(*)
FROM iceberg.analytics.events
WHERE metadata_map['plan'] = 'pro'
GROUP BY 1;
```

A MAP column is better than VARCHAR because Trino reads only the map column (not the whole row) and the data is stored in Parquet's columnar format. However, MAP values are all `VARCHAR` — no type safety, no numeric comparisons — and predicate pushdown still doesn't apply to map element access. Use this when you need more flexibility than Option B but can't enumerate every key upfront.

### Which option to pick

| Scenario | Approach |
|---|---|
| 5–10 keys queried in dashboards | Option B: flatten hot keys into typed columns |
| Schema is unpredictable, keys vary wildly | Option C: MAP column, accept no pushdown |
| Rare one-off ad-hoc queries only | Option A: json_extract_scalar on VARCHAR, acceptable at small scale |

For most SaaS analytics pipelines, a hybrid works best: flatten the known hot keys (plan, device_type, feature_name) via Option B, and keep `metadata_raw` for everything else.

### Adding a new key later is cheap

When a new key becomes a hot query target (say `region` starts appearing in WHERE clauses):

1. Add the column in Trino — metadata-only, instant:
   ```sql
   ALTER TABLE iceberg.analytics.events ADD COLUMN region VARCHAR;
   ```
2. Update the Spark job to extract `region` with `get_json_object`.
3. New rows get the `region` value; old rows return `NULL` automatically — Iceberg handles partial columns.
4. If historical values matter, run a one-time Spark job to backfill from `metadata_raw`.
