# Iter55 Q2 — Answer

**Question**: Our Postgres events table has a column called `properties` that's stored as JSONB. Every event type uses it differently — a `page_viewed` event might have `{"url": "/dashboard", "referrer": "google.com"}`, a `feature_used` event has `{"feature_name": "export", "plan_type": "pro"}`, and some events have a `tags` key that's actually a JSON array like `["enterprise", "beta"]`. When we set up our Spark job to load this table into Iceberg, we're not sure what to do with this column since Parquet won't have a JSONB type. Can we just cast it to a string and dump it as-is? Or do we need to break it apart into separate columns? We care most about being able to filter and group by things like `feature_name` and `plan_type` in our Trino dashboards later.

---

## Answer

You have two real options here. Let me explain what each means, why the second is almost always better, and how to handle array fields like `tags`.

### Option 1: store the whole blob as a string (simple, but slow)

Yes, you can cast the entire JSONB column to a VARCHAR (text string) in Iceberg. Parquet has no native JSON type, so this works technically. Later, when you query from Trino, you'd use a function like `json_extract_scalar(properties, '$.feature_name')` to pull out individual fields on the fly.

**The problem:** Trino has to parse that JSON string **every single time** someone runs a dashboard that filters or groups by `feature_name`. For a table with millions of rows, this re-parsing becomes expensive. You also lose columnar compression benefits — the entire blob lives as one string column, so Trino can't compress the `feature_name` values separately.

Use this only if the `properties` blob is truly ad-hoc and barely queried.

### Option 2: extract the hot fields at ingest time (recommended)

In your Spark job, pull out the top 5–10 most-queried JSON keys (like `feature_name` and `plan_type`) into real typed columns. Keep the original blob as `properties_raw VARCHAR` for the rare fields and edge cases.

Here's what that looks like in code:

```python
from pyspark.sql.functions import get_json_object

# Extract the hot fields you actually GROUP BY or WHERE on
df = df.withColumn("feature_name", get_json_object("properties", "$.feature_name")) \
       .withColumn("plan_type", get_json_object("properties", "$.plan_type")) \
       .withColumn("device_type", get_json_object("properties", "$.device_type")) \
       .withColumnRenamed("properties", "properties_raw")
```

Now in Iceberg you have three real columns: `feature_name`, `plan_type`, `device_type` (all VARCHAR). The original blob lives in `properties_raw`. Your Trino dashboard queries become simple:

```sql
SELECT feature_name, plan_type, COUNT(*)
FROM iceberg.analytics.events
GROUP BY 1, 2;
```

No JSON parsing. Fast. Compresses well.

**The rule of thumb:** extract anything you GROUP BY, WHERE, or JOIN ON. Leave everything else in `properties_raw`.

### Handling the array case (tags)

For the `tags` field which is a JSON array like `["enterprise", "beta"]`, you have two approaches depending on what you need:

**If you just need the first tag or a specific index,** use index syntax:

```python
df = df.withColumn("first_tag", get_json_object("properties", "$.tags[0]"))
```

**If you need to check whether the array contains a specific value** (like "is this event tagged 'enterprise'?"), do NOT use `.contains()` on the string — that's a substring match and would incorrectly match "enterprise-plus". Instead, parse the array and use proper array containment:

```python
from pyspark.sql.functions import from_json, array_contains
from pyspark.sql.types import ArrayType, StringType

tags_schema = ArrayType(StringType())
df = df.withColumn("tags_array", from_json(get_json_object("properties", "$.tags"), tags_schema)) \
       .withColumn("has_enterprise_tag", array_contains(col("tags_array"), "enterprise"))
```

Now `has_enterprise_tag` is a boolean column you can filter and group on efficiently.

### What happens if you add a new hot field later?

You don't need to reload the entire table. Just:

1. Add the new column to Iceberg (this is a metadata-only operation, takes milliseconds even on a huge table):
   ```sql
   ALTER TABLE iceberg.analytics.events ADD COLUMN new_field VARCHAR;
   ```

2. Update your Spark job to extract the new field going forward.

3. Old rows in Iceberg automatically return NULL for the new column — no backfill required unless you specifically want historical values extracted.

### Why this matters for your team

By extracting the hot fields now, your dashboards stay fast even as event volume grows. The extracted columns are first-class in Parquet — Iceberg can compress them, Trino can skip entire files during queries, and new analysts don't have to learn JSON extraction syntax. The `properties_raw` fallback means you never lose data; it's there if someone later needs a field you didn't extract.
