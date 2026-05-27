# Iter100 Q2 — Answer

**Question**: We're using Debezium to stream changes from our Postgres database into Iceberg, and it's been working fine for our regular columns. But one of our tables has a JSONB column where customers store arbitrary metadata — and different customers put completely different keys in there. Now a customer wants to filter their dashboard by a specific key inside that JSONB blob. I'm not sure how to handle this: do I just store the whole JSON blob as a string in Iceberg and parse it at query time, or is there a better way to handle evolving JSONB structure that doesn't require me to rewrite the whole table every time someone adds a new key?

---

## Answer

Great question. This is one of the trickiest parts of streaming Postgres into a lakehouse, because JSONB in Postgres has no schema — but Parquet (which backs your Iceberg tables) demands one. The good news: there's a proven pattern that scales with your customers' needs without rewrites.

### What Debezium does with JSONB

When Debezium reads your Postgres table via the WAL (write-ahead log), it sees the JSONB column as opaque binary data. It emits the entire JSON blob as a single string in the Kafka message — there's no built-in Debezium setting to auto-expand `{"device_type":"mobile","region":"EU"}` into separate typed fields. That expansion is your job, and **this is by design** because JSONB has no fixed schema — different customers can have completely different keys, and trying to pre-define a struct with one field per JSON key loses that flexibility.

Debezium just passes the whole blob through as a VARCHAR. You decide what to do with it on the Spark consumer side.

### The recommended pattern: split into two layers

The practical answer splits your JSON handling into two layers — storage and query time — rather than picking one extreme or the other.

**Layer 1 (ingest): extract the "hot" keys into real columns**

At ingest time in your Spark Structured Streaming consumer, extract the 5-10 JSONB keys that appear frequently in customer queries. These become first-class columns in your Iceberg table:

```python
from pyspark.sql.functions import get_json_object

events_delta = events_delta \
    .withColumn("device_type", get_json_object("properties_raw", "$.device_type")) \
    .withColumn("region", get_json_object("properties_raw", "$.region")) \
    .withColumn("customer_segment", get_json_object("properties_raw", "$.customer_segment"))

spark.sql("""
    MERGE INTO iceberg.analytics.events t
    USING events_delta s
    ON t.event_id = s.event_id
    WHEN MATCHED AND s.op = 'd' THEN DELETE
    WHEN MATCHED AND s.op = 'u' THEN UPDATE SET *
    WHEN NOT MATCHED AND s.op IN ('c', 'r') THEN INSERT *
""")
```

These extracted columns are stored with Parquet's dictionary encoding (because they're low-cardinality strings like "mobile", "web", "EU", "US"), so storage is cheap and queries are fast. Your dashboard can filter directly on `WHERE device_type = 'mobile'` without any JSON parsing.

**Layer 2 (query time): JSON extraction for the long tail**

For keys that customers eventually ask about but are infrequent or highly variable, keep the original JSON blob as a VARCHAR column (`properties_raw`). At query time, use Trino's JSON functions to extract from it:

```sql
SELECT 
    device_type,
    JSON_VALUE(properties_raw, '$.custom_field_x' RETURNING varchar NULL ON EMPTY NULL ON ERROR) AS field_x,
    COUNT(*) AS event_count
FROM iceberg.analytics.events
WHERE occurred_at >= CURRENT_DATE - INTERVAL '7' DAY
GROUP BY 1, 2;
```

Trino 467 supports two JSON extraction functions:

- **`json_extract_scalar(properties_raw, '$.key')`** — simpler, silently returns NULL for both missing keys and malformed JSON.
- **`JSON_VALUE(properties_raw, '$.key' RETURNING varchar NULL ON EMPTY NULL ON ERROR)`** — SQL/JSON standard, more explicit about error handling. Use this when you want to distinguish "key was absent" from "JSON was corrupt."

For the customer who wants to filter by a specific key: if it's a new key that wasn't in your original extraction list, just add a `JSON_VALUE(properties_raw, '$.that_key')` to your dashboard query. **No table rewrite needed.** The Iceberg table schema doesn't change because the raw JSON blob's type is still VARCHAR.

### Schema evolution when new JSON keys appear

This is the key advantage of the two-layer approach. When customers add new JSONB keys:

| What happens in Postgres | What happens in Iceberg | What happens to dashboards |
|---|---|---|
| App starts writing `properties->>'ab_variant'` | Debezium streams the full JSON blob (with the new key inside) as VARCHAR. Zero schema changes in Iceberg. | Dashboards querying old extracted columns (like `device_type`) continue working. A dashboard asking for `ab_variant` uses `JSON_VALUE(properties_raw, '$.ab_variant')` and gets NULL on old rows, real values on new rows. |
| App removes an old rarely-used key | Blob is just shorter. | `JSON_VALUE` returns NULL. No errors. |
| App changes a key's type (e.g., `tags` was `"enterprise"`, now `["enterprise","beta"]`) | The VARCHAR still stores it faithfully. | **Downstream break** — a dashboard that assumed `tags` was a string gets `["enterprise","beta"]` as literal text. This is a consumer-layer contract break, not a pipeline failure. |

**Key insight:** the pipeline (Debezium → Spark → Iceberg) never breaks when JSON keys are added, removed, or retyped. Downstream consumers that assumed a fixed JSON shape may need code review, but that's separate from pipeline stability.

### Avoiding the anti-patterns

**Do NOT store JSONB as Iceberg `MAP<STRING,STRING>` or `STRUCT`:**

- **`MAP<STRING,STRING>`** loses type information (numeric `42` becomes string `"42"`), adds query overhead, and can't represent nested objects.
- **`STRUCT`** requires the schema to match the JSON key set exactly. Every new JSONB key forces an `ALTER TABLE ... ADD COLUMN`, and every removed key leaves a dead field. This turns schema evolution into a coordinated production change.

Both anti-patterns make schema evolution harder, not easier. The VARCHAR + extraction pattern keeps it transparent.

### Implementation timeline for your customer

**Today — answer the immediate question:**

Add a Trino query to your dashboard extracting the key the customer wants:

```sql
SELECT 
    event_date,
    JSON_VALUE(properties_raw, '$.the_key_customer_wants' RETURNING varchar NULL ON EMPTY NULL ON ERROR) AS customer_key,
    COUNT(*) AS event_count
FROM iceberg.analytics.events
WHERE occurred_at >= CURRENT_DATE - INTERVAL '30' DAY
GROUP BY 1, 2;
```

No code change, no backfill, no table rebuild. The customer can filter by `customer_key` immediately.

**This week — if this key gets queried by 3+ dashboards:**

Add it to your Spark consumer's extraction layer:

```python
.withColumn("the_key_customer_wants", get_json_object("properties_raw", "$.the_key_customer_wants"))
```

Then `ALTER TABLE iceberg.analytics.events ADD COLUMN the_key_customer_wants VARCHAR` — metadata-only, instant. The next Spark run populates it for new events; old events return NULL automatically (no backfill needed unless you need historical non-NULL values).

**Ongoing — promote frequently-queried keys:**

Track which JSON keys get queried most often from `properties_raw`. Every key that appears in 5+ dashboards or drives row-level filtering should graduate to a real column. The rule of thumb: flatten what you `GROUP BY`, `WHERE`, or `JOIN ON` — leave the long tail in the raw blob.

## Summary

- **Debezium streams JSONB as a VARCHAR string** — no auto-expansion into typed fields. There's no Debezium config to enable this; it's by design.
- **Extract hot keys (top 5-10) at ingest time** into real Iceberg columns for fast filtering and compression.
- **Keep the raw blob for the long tail.** Use `JSON_VALUE()` or `json_extract_scalar()` at query time for keys you didn't pre-extract.
- **Answer today's question immediately** with a query-time JSON extraction — no table change needed.
- **Schema evolution is transparent at the pipeline level.** New keys appear in the blob automatically. Only downstream consumers that assumed a fixed JSON shape need updates.
