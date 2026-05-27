# Iter103 Q2 — Answer

**Question**: We have two separate Postgres databases: one in the US and one in the EU, for data residency reasons. Both have the same schema and we're running Debezium on each. We want to feed both into a single Iceberg table for analytics — but we're worried about primary key collisions since both databases have their own auto-incrementing IDs starting from 1. How do people handle merging CDC streams from two separate source databases into one analytics table? Do we need to transform the keys somehow, or is there a standard pattern for this?

---

## Answer

Yes, you must handle PK collisions. The standard solution is a **composite key pattern** where you include a source-database identifier alongside the original primary key.

### Part (a): Why PK collisions break MERGE INTO

MERGE INTO decides "is this incoming row already in the target table?" using the `ON` clause. If you only join on the original `id`:

```sql
MERGE INTO iceberg.analytics.events t
USING source_delta s
ON t.id = s.id  -- WRONG: id=42 from US and id=42 from EU collide
```

A US row with `id=42` and an EU row with `id=42` incorrectly match — MERGE updates the existing US event with EU data, silently overwriting one. You get data corruption with no error message. Row counts are wrong, user associations are wrong.

### Part (b): The standard solution — composite key with source identifier

Add a `source_region` column to your Iceberg table and use `(id, source_region)` as your composite join key:

```sql
CREATE TABLE iceberg.analytics.events (
    id             BIGINT,
    source_region  VARCHAR,   -- 'us' or 'eu' — makes key globally unique
    tenant_id      BIGINT,
    user_id        BIGINT,
    event_ts       TIMESTAMP,
    event_payload  VARCHAR,
    source_lsn     BIGINT,    -- Debezium WAL position per source
    ingested_at    TIMESTAMP
)
USING iceberg
PARTITIONED BY (day(event_ts), source_region);
```

MERGE INTO with composite join key:

```sql
MERGE INTO iceberg.analytics.events t
USING events_delta s
ON  t.id            = s.id
AND t.source_region = s.source_region
WHEN MATCHED THEN UPDATE SET
    user_id       = s.user_id,
    event_ts      = s.event_ts,
    event_payload = s.event_payload,
    source_lsn    = s.source_lsn,
    ingested_at   = s.ingested_at
WHEN NOT MATCHED THEN INSERT *
```

Now `(id=42, source_region='us')` and `(id=42, source_region='eu')` are distinct rows — both are correctly inserted.

**Critical:** omitting `source_region` from the `ON` clause is the most common multi-source bug. It works in testing (small data, no collisions by chance), then silently corrupts production data when real collisions occur.

### Part (c): Populating source_region from Debezium

Set different `topic.prefix` per connector in your Debezium config:
- US connector: `topic.prefix: "us-prod"` → events land on `us-prod.public.events`
- EU connector: `topic.prefix: "eu-prod"` → events land on `eu-prod.public.events`

In your Spark Structured Streaming consumer, subscribe to both topics and parse the region from the topic name:

```python
from pyspark.sql.functions import col, split, when, get_json_object

df = (spark.readStream
    .format("kafka")
    .option("kafka.bootstrap.servers", "kafka:9092")
    .option("subscribe", "us-prod.public.events,eu-prod.public.events")
    .load()
)

df = df \
    .withColumn("source_region",
        when(split(col("topic"), "\\.")[0] == "us-prod", "us")
        .when(split(col("topic"), "\\.")[0] == "eu-prod", "eu")
        .otherwise("unknown")
    ) \
    .withColumn("payload", col("value").cast("string")) \
    .withColumn("id",           get_json_object(col("payload"), "$.after.id")) \
    .withColumn("tenant_id",    get_json_object(col("payload"), "$.after.tenant_id")) \
    .withColumn("event_ts",     get_json_object(col("payload"), "$.after.event_ts")) \
    .withColumn("event_payload",get_json_object(col("payload"), "$.after.event_payload")) \
    .withColumn("source_lsn",   get_json_object(col("payload"), "$.source.lsn")) \
    .withColumn("op",           get_json_object(col("payload"), "$.op"))
```

Also store `source_lsn` (Debezium's WAL position) per source — it's per-database, so both sources can have the same LSN values. Storing it lets you diagnose per-region replication lag.

### Part (d): Data residency considerations

Merging EU and US Postgres CDC into a single Iceberg table creates a data residency tension. If your on-prem cluster is in the EU, US data flowing there is typically fine. If it's in the US, GDPR may apply to EU data.

Regardless of where the cluster runs, enforce regional isolation at the query layer — just like per-tenant isolation:

```sql
-- EU users see only EU-sourced rows
CREATE VIEW analytics_eu.events AS
  SELECT * FROM analytics.events
  WHERE source_region = 'eu';

GRANT SELECT ON analytics_eu.events TO ROLE eu_analytics_role;
REVOKE ALL PRIVILEGES ON analytics.events FROM USER "eu-analyst-service-account";
```

If physical geographic isolation is a hard legal requirement (data must never leave a jurisdiction), you cannot merge into a single table. You would need two separate Iceberg deployments (US cluster, EU cluster), each with their own MinIO. This is a significant operational change beyond the current single on-prem stack.

### Implementation checklist

- [ ] Add `source_region` column to Iceberg table (VARCHAR, NOT NULL)
- [ ] Set different `topic.prefix` per Debezium connector (e.g., `us-prod`, `eu-prod`)
- [ ] Subscribe to both Kafka topics in the Spark consumer
- [ ] Parse `source_region` from the Kafka topic name
- [ ] Use `ON t.id = s.id AND t.source_region = s.source_region` in MERGE INTO
- [ ] Add `source_lsn` column for per-source WAL position tracking
- [ ] Partition by `(day(event_ts), source_region)` for efficient per-region queries
- [ ] Test with IDs that genuinely collide (both sources produce `id=1`) to verify both rows land correctly
- [ ] Create per-region Trino views if query-layer residency enforcement is required
