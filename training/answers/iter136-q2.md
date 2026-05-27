# Iter136 Q2 — Answer

**Question**: "We're using Debezium to stream row changes from Postgres into Iceberg. Most columns are fine — ints, timestamps, text fields all come through cleanly. But one of our tables has a `jsonb` column called `metadata` that different customers use in completely different ways: some put flat key-value pairs in it, some put deeply nested objects, and customers keep adding new fields to their own JSON structure over time. When I try to land this in Iceberg, I don't know how to model the column. If I try to infer a schema from the JSONB contents, the structures are incompatible across tenants and keep changing. What do people actually do in this situation — do you store the whole JSONB blob as a raw string in Iceberg and query it later, or is there a way to map it into typed Iceberg columns? And if a customer starts using a new nested key six months from now, what's the migration story — does the Iceberg table need to be updated every time someone's JSON evolves?"

---

## The Answer: Use the Two-Tier Pattern

Don't choose between raw string OR typed columns — use both. This is the **two-tier pattern**, and it's the standard approach for multi-tenant SaaS with heterogeneous JSONB:

- **Tier 1 (hot columns):** Extract the 5–10 most-queried JSON keys into typed top-level Iceberg columns. These get Parquet compression, min/max statistics, and file-level pruning — your dashboards run 10–50x faster on them.
- **Tier 2 (raw fallback):** Keep the full JSON blob as a `VARCHAR` column. Query it with `json_extract_scalar()`. No schema changes needed when customers add new keys.

```
events (
  event_id      VARCHAR,
  user_id       VARCHAR,
  tenant_id     VARCHAR,
  occurred_at   TIMESTAMP(6),
  -- Tier 1: promoted hot columns (typed, file-prunable)
  plan_tier     VARCHAR,         -- extracted from metadata->'plan_tier'
  device_type   VARCHAR,         -- extracted from metadata->'device_type'
  feature_name  VARCHAR,         -- extracted from metadata->'feature_name'
  -- Tier 2: raw fallback for everything else
  metadata_raw  VARCHAR          -- full JSONB as a JSON string
)
PARTITIONED BY (day(occurred_at), tenant_id)
```

---

## What Debezium Actually Sends for JSONB

Debezium serializes Postgres `JSONB` as a UTF-8 JSON **string** in the change-event `after` payload (via the `io.debezium.data.Json` semantic type). You don't need special Debezium configuration — it arrives as a string. No auto-expansion into typed columns happens on the Debezium side; that flattening is your job in the Spark consumer.

---

## Building the Two-Tier Table: Spark Flattening

Your Spark Structured Streaming job parses the Debezium envelope and extracts hot keys before writing to Iceberg:

```python
from pyspark.sql.functions import get_json_object, from_json, col
from pyspark.sql.types import StructType, StructField, StringType, LongType

# Define the "after" image schema (Postgres table columns)
after_schema = StructType([
    StructField("event_id",    StringType()),
    StructField("user_id",     StringType()),
    StructField("tenant_id",   StringType()),
    StructField("occurred_at", LongType()),   # Debezium encodes timestamps as epoch microseconds
    StructField("metadata",    StringType()), # JSONB arrives as a JSON string
])

def process_batch(batch_df, batch_id):
    if batch_df.isEmpty():
        return

    # Parse Debezium envelope
    parsed = batch_df.select(
        from_json(
            col("value").cast("string"),
            StructType([
                StructField("op",    StringType()),
                StructField("after", after_schema),
            ])
        ).alias("e")
    ).select("e.*").filter(col("op").isin("c", "u", "r"))

    # Flatten: extract hot JSON keys + keep raw blob
    flattened = parsed.select(
        col("after.event_id"),
        col("after.user_id"),
        col("after.tenant_id"),
        col("after.occurred_at"),
        # Tier 1: typed, promoted hot columns
        get_json_object(col("after.metadata"), "$.plan_tier").cast("string").alias("plan_tier"),
        get_json_object(col("after.metadata"), "$.device_type").cast("string").alias("device_type"),
        get_json_object(col("after.metadata"), "$.feature_name").cast("string").alias("feature_name"),
        # Tier 2: raw fallback (no transformation)
        col("after.metadata").alias("metadata_raw"),
    )

    flattened.createOrReplaceTempView("cdc_events")
    spark.sql("""
        MERGE INTO iceberg.analytics.events t
        USING cdc_events s ON t.event_id = s.event_id
        WHEN MATCHED THEN UPDATE SET *
        WHEN NOT MATCHED THEN INSERT *
    """)

spark.readStream \
    .format("kafka") \
    .option("kafka.bootstrap.servers", "kafka:9092") \
    .option("subscribe", "postgres.public.events") \
    .load() \
    .writeStream \
    .foreachBatch(process_batch) \
    .option("checkpointLocation", "s3a://lakehouse/checkpoints/events") \
    .trigger(processingTime="60 seconds") \
    .start() \
    .awaitTermination()
```

`get_json_object(col, "$.key")` returns `NULL` for missing keys — safe for any tenant's JSON structure, including ones that don't use `plan_tier` at all.

---

## Querying in Trino 467

### Hot columns: fast, file-prunable

```sql
-- Trino uses min/max stats to skip files — 10–50x faster than JSON parsing
SELECT plan_tier, device_type, COUNT(*) AS events
FROM iceberg.analytics.events
WHERE occurred_at >= CURRENT_DATE - INTERVAL '7' DAY
  AND plan_tier = 'enterprise'
GROUP BY plan_tier, device_type;
```

### Raw JSON fallback: flexible, slower

```sql
-- json_extract_scalar returns a string; returns NULL for missing keys
SELECT json_extract_scalar(metadata_raw, '$.custom_partner_id') AS partner_id,
       COUNT(*) AS events
FROM iceberg.analytics.events
WHERE occurred_at >= CURRENT_DATE - INTERVAL '30' DAY
GROUP BY 1;

-- json_value (SQL/JSON standard, available in Trino 467) — explicit type casting
SELECT json_value(metadata_raw, '$.price' RETURNING DECIMAL) AS price,
       COUNT(*) AS events
FROM iceberg.analytics.events
WHERE json_value(metadata_raw, '$.is_trial' RETURNING BOOLEAN) = true
GROUP BY 1;
```

`json_extract_scalar` is simpler but returns NULL silently for both missing keys and malformed JSON. `json_value` lets you specify `NULL ON EMPTY` vs `ERROR ON ERROR` — use it when you want explicit error handling.

---

## Schema Evolution: What Happens When New JSON Keys Appear

### New key appears in `metadata_raw` (the common case)

**Nothing breaks. Zero changes required.**

A customer starts sending `metadata->>'ab_variant': 'experiment_123'` for the first time. Debezium captures the full JSON blob unchanged and writes it to `metadata_raw` as a string. The Iceberg schema doesn't change — `metadata_raw` is still `VARCHAR`. Trino can query the new key immediately:

```sql
SELECT json_extract_scalar(metadata_raw, '$.ab_variant') AS variant,
       COUNT(*) AS events
FROM iceberg.analytics.events
WHERE occurred_at >= CURRENT_DATE - INTERVAL '7' DAY
GROUP BY 1;
```

Returns the value for new rows and `NULL` for old rows (before the customer started sending this field). That's correct behavior.

**This is the whole point of the two-tier pattern:** your pipeline is immune to source-side schema drift. New JSON keys land silently in the raw blob. No alerts. No downtime. No `ALTER TABLE`.

### Promoting a new key to a typed column

When a formerly-rare key starts showing up on many dashboards and you want file-pruning performance on it:

**Step 1: Add the column to Iceberg (metadata-only)**

```sql
-- In Trino 467 — instant, no data rewrite
ALTER TABLE iceberg.analytics.events
ADD COLUMN ab_variant VARCHAR;
```

Old rows automatically return `NULL` for `ab_variant`. New rows (written after this) have the real value.

**Step 2: Update your Spark job to extract the new key**

Add to the `flattened` select:
```python
get_json_object(col("after.metadata"), "$.ab_variant").cast("string").alias("ab_variant"),
```

**Step 3 (optional but recommended): Backfill historical rows**

```python
spark.sql("""
    MERGE INTO iceberg.analytics.events t
    USING (
        SELECT event_id,
               json_extract_scalar(metadata_raw, '$.ab_variant') AS ab_variant
        FROM iceberg.analytics.events
        WHERE ab_variant IS NULL
    ) s
    ON t.event_id = s.event_id
    WHEN MATCHED THEN UPDATE SET t.ab_variant = s.ab_variant
""")
```

Only after the backfill should you repoint dashboards from `json_extract_scalar(metadata_raw, '$.ab_variant')` to the typed `ab_variant` column. Verify first:

```sql
-- Should be ~0 nulls for dates where you know this field was present
SELECT COUNT(*) FROM iceberg.analytics.events
WHERE ab_variant IS NULL AND occurred_at >= '2026-01-01';
```

---

## Which Keys to Promote to Typed Columns

Promote when:
- The key appears in `GROUP BY` or `WHERE` on multiple dashboards (not just one ad-hoc query)
- Cardinality is low enough for dictionary compression (< ~10K distinct values)
- You want the column to be usable in Trino's file-pruning (for WHERE filters)
- The field is universal or near-universal across tenants (not one tenant's quirk)

Keep in `metadata_raw` when:
- Queried rarely (engineer ad-hoc analysis, not dashboards)
- Tenant-specific — only 1–3 tenants use this key
- Extremely high cardinality (full URLs, per-event trace IDs)
- Changes definition frequently or is structurally inconsistent across tenants

For your 80-tenant scenario: assume most custom fields stay in `metadata_raw`. Promote only the 5–10 keys that show up in cross-customer dashboards.

---

## Schema Migration Story: Summary Table

| Scenario | Iceberg schema change needed? | Pipeline change needed? |
|---|---|---|
| Customer adds new JSON key, you don't care about performance | **No** — lands silently in `metadata_raw` | **No** |
| Customer adds new JSON key, you want typed access for performance | `ALTER TABLE ADD COLUMN` (metadata-only, instant) | Add `get_json_object(...)` to Spark job |
| Customer changes type of existing key (e.g., string → number) | **No** — `json_extract_scalar` returns a string; cast in Trino | **No** (unless you're parsing with `json_value RETURNING INT`) |
| Customer removes a JSON key | **No** — `json_extract_scalar` returns NULL for missing keys | **No** |
| Promoted typed column needs to change type | `ALTER TABLE CHANGE COLUMN` | Update Spark job cast |

---

## Practical Notes for Your Stack (Iceberg 1.5.2 + Trino 467 + MinIO)

**Streaming small files:** your 60-second micro-batches create many small Parquet files. Schedule a nightly compaction:

```python
spark.sql("""
    CALL iceberg.system.rewrite_data_files(
        table   => 'analytics.events',
        options => map('target-file-size-bytes', '268435456')
    )
""")
```

**JSONB querying in MAP type (alternative):** Iceberg supports a `MAP<VARCHAR, VARCHAR>` type which allows `element_at(metadata_map, 'plan_tier')` queries. This gives slightly better Parquet encoding for simple flat key-value metadata (no nested objects). If your metadata is truly flat (not nested), consider this instead of a raw JSON string. If it's nested or variable in structure, stick with `VARCHAR` + `json_extract_scalar`.

**NULL safety:** `json_extract_scalar` returns NULL for missing keys silently. If you need to distinguish "key missing" from "key present with null value," use `json_extract` (returns `null` as the JSON literal string `"null"`) combined with a NULL check.

---

## Summary

1. **Use the two-tier pattern:** promote 5–10 hot keys to typed Iceberg columns; keep full JSON blob in a `VARCHAR` fallback column.
2. **Debezium sends JSONB as a UTF-8 JSON string** — no special configuration needed. Extract keys in your Spark consumer with `get_json_object()`.
3. **New JSON keys require no Iceberg schema change** — they land silently in `metadata_raw`. Query with `json_extract_scalar(metadata_raw, '$.new_key')` immediately.
4. **Promote keys to typed columns only when they become dashboard-hot** — `ALTER TABLE ADD COLUMN` is metadata-only in Iceberg 1.5.2, then backfill from `metadata_raw`.
5. **Never infer schema from JSONB at ingestion time** — incompatible structures across tenants will cause type conflicts or data loss.
