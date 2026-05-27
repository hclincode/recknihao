# Iter72 Q2 — Answer

**Question**: We have a `user_preferences` table in Postgres with no `created_at` or `updated_at` column — just a primary key and data columns. Our normal watermark-based incremental sync can't work without a timestamp. Someone mentioned Postgres has "logical replication" that watches an internal change log. Is that a real option for a table with no timestamp columns? What would it look like, and is it significantly more complicated?

---

## Answer

Logical replication is a real option, and Debezium is the standard tool for it. But before I explain the setup, I want to give you an honest assessment: for a `user_preferences` table specifically, the simpler answer might just be a nightly full reload. Let me cover both.

### Why your watermark approach can't work here

Your watermark-based sync works by querying `WHERE updated_at > last_run_timestamp`. Without `updated_at`, there's no column to filter on — you have to read the entire table every run. If the table is small (< a few million rows), this is fine. If it's large and changes frequently, it's wasteful.

**Simplest fix: nightly full reload**

```python
df = spark.read.jdbc(
    url="jdbc:postgresql://pg-primary:5432/app",
    table="public.user_preferences",
    properties={
        "user": PG_USER,
        "password": PG_PASS,
        "fetchsize": "10000",
    }
)
df.writeTo("iceberg.analytics.dim_user_preferences").using("iceberg").createOrReplace()
```

This requires zero changes to Postgres, zero new infrastructure, and handles dimension tables up to ~10M rows in minutes. If `user_preferences` is 100K rows, this runs in seconds. For a preferences table that changes infrequently, this is the right answer.

**When to use CDC instead:**
- The table is large enough that a full reload is meaningfully slow
- Changes must propagate within minutes, not hours
- You need to capture hard deletes accurately (a full reload re-reads current state but won't show you what was deleted — you'd need to diff)

If none of those apply, stop here and use the full reload.

### What Postgres logical replication actually is

Postgres maintains a **write-ahead log (WAL)** — its internal transaction journal. Every INSERT, UPDATE, and DELETE is recorded there before it's applied to the table. **Logical replication** is a Postgres feature that lets external tools read this WAL as a stream of structured change events.

Debezium is the standard tool that reads this WAL stream and publishes each change as a JSON message to Kafka — without needing any `updated_at` column in the source table.

### The CDC architecture

```
Postgres WAL → Debezium connector → Kafka topic → Spark Structured Streaming → Iceberg (MinIO)
```

All components can run on your existing on-prem Kubernetes cluster. The key new pieces are Debezium and Kafka (Spark and Iceberg you already have).

### Setting up Debezium for your table

**Postgres prerequisites (one-time, no schema change needed):**
```sql
-- Create a replication user
CREATE ROLE replication_user WITH REPLICATION LOGIN PASSWORD 'secret';
GRANT SELECT ON public.user_preferences TO replication_user;

-- Create a publication (tells Postgres which tables to expose)
CREATE PUBLICATION user_prefs_pub FOR TABLE public.user_preferences;
```

**Debezium connector configuration:**
```json
{
  "name": "postgres-user-preferences-connector",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "database.hostname": "pg-primary",
    "database.port": "5432",
    "database.user": "replication_user",
    "database.password": "secret",
    "database.dbname": "app",
    "plugin.name": "pgoutput",
    "publication.name": "user_prefs_pub",
    "tables.include.list": "public.user_preferences",
    "slot.name": "user_prefs_slot",
    "topic.prefix": "postgres"
  }
}
```

**What Debezium publishes to Kafka for each change:**
```json
{
  "op": "u",
  "before": {"user_id": 123, "notification_email": "old@example.com", "theme": "light"},
  "after":  {"user_id": 123, "notification_email": "new@example.com", "theme": "light"},
  "ts_ms": 1716547200000
}
```

`op` values: `i` (insert), `u` (update), `d` (delete). Debezium generates these **without any `updated_at` column** — it reads from the WAL.

### Consuming changes in Spark

A long-running Spark Structured Streaming job subscribes to Kafka and merges into Iceberg:

```python
spark = SparkSession.builder \
    .config("spark.sql.catalog.iceberg", "org.apache.iceberg.spark.SparkCatalog") \
    .config("spark.sql.catalog.iceberg.type", "hive") \
    .config("spark.sql.catalog.iceberg.uri", "thrift://hive-metastore:9083") \
    .config("spark.sql.catalog.iceberg.warehouse", "s3a://lakehouse/warehouse") \
    .getOrCreate()

raw = spark.readStream \
    .format("kafka") \
    .option("kafka.bootstrap.servers", "kafka:9092") \
    .option("subscribe", "postgres.public.user_preferences") \
    .load()

# Parse Debezium JSON
schema = "op STRING, after STRUCT<user_id:LONG, notification_email:STRING, theme:STRING>, ts_ms LONG"
parsed = raw.select(from_json(col("value").cast("string"), schema).alias("m")).select("m.*")

def merge_to_iceberg(batch_df, batch_id):
    batch_df.createOrReplaceTempView("cdc_batch")
    spark.sql("""
        MERGE INTO iceberg.analytics.dim_user_preferences t
        USING cdc_batch s ON t.user_id = s.after.user_id
        WHEN MATCHED AND s.op = 'u' THEN UPDATE SET
            t.notification_email = s.after.notification_email,
            t.theme = s.after.theme
        WHEN MATCHED AND s.op = 'd' THEN DELETE
        WHEN NOT MATCHED AND s.op IN ('i', 'u') THEN INSERT (user_id, notification_email, theme)
            VALUES (s.after.user_id, s.after.notification_email, s.after.theme)
    """)

parsed.writeStream \
    .foreachBatch(merge_to_iceberg) \
    .option("checkpointLocation", "s3a://lakehouse/checkpoints/user_prefs") \
    .start() \
    .awaitTermination()
```

The checkpoint in MinIO ensures the streaming job can resume from where it left off after a crash — no changes are missed and no changes are double-applied.

**Important Debezium config for your Iceberg sink**: Trino resource `resources/13-postgres-to-iceberg-ingestion.md` notes the correct config property for schema evolution in the Iceberg sink is `debezium.sink.iceberg.allow-field-addition=true` (not `schema.evolution=basic`, which is the JDBC sink connector property).

### Honest complexity assessment

| Dimension | Full nightly reload | CDC with Debezium |
|---|---|---|
| Infrastructure added | Nothing new | Debezium connector + Kafka |
| Postgres changes | None | Replication user + publication |
| Spark job | Nightly batch (simple) | Continuous streaming (more ops) |
| Freshness | Daily | Sub-minute |
| Handles hard deletes? | No (must diff to detect) | Yes (captures DELETE events) |
| Operational overhead | Low | Medium (three services to monitor) |

CDC is not dramatically harder, but it does introduce three services to operate (Debezium, Kafka, a continuous Spark job) instead of one nightly CronJob. For a `user_preferences` table where sub-minute freshness isn't a business requirement, that overhead is usually not worth it.

### Recommendation for your specific table

Start with the **nightly full reload**. It requires no infrastructure changes, handles any table regardless of schema, and completes in seconds for preference-sized data. Revisit CDC if:
1. The table grows beyond ~10M rows and the full reload becomes slow
2. You need changes to propagate in real time (< 5 minutes)
3. You need to capture deletes accurately without running a diff
