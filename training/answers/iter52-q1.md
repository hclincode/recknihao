# Iter52 Q1 Answer — Debezium CDC and Iceberg Schema Evolution

When a developer adds a new column to your Postgres table with `ALTER TABLE events ADD COLUMN device_os VARCHAR(50)`, here's what actually happens:

## Debezium detects the DDL change

Debezium doesn't silently fail or ignore the change. It reads the Postgres write-ahead log (WAL) through the logical replication slot and detects the DDL via a schema registry — either Confluent Schema Registry or Apicurio. The connector emits Kafka messages with the new field present.

## The schema mismatch problem

The Iceberg table's schema and the incoming Debezium messages are now **out of sync**. Rows that existed *before* the `ALTER TABLE` have the new field missing in their Kafka message (Debezium can only include columns that existed at capture time). Rows added *after* the `ALTER TABLE` have the field present.

When the Spark or Flink consumer tries to write these messages to Iceberg, it will fail or silently drop the new field because Iceberg doesn't have a column called `device_os` yet.

## The fix: schema-first approach

Before resuming the consumer, add the column to Iceberg in Spark SQL:

```sql
ALTER TABLE iceberg.analytics.events ADD COLUMN device_os VARCHAR;
```

**This is a metadata-only operation** — Iceberg doesn't rewrite Parquet files. It completes in milliseconds even on a 10 TB table. Rows that existed before the `ALTER TABLE` will return `NULL` for the new column when queried (Iceberg tracks columns by internal field ID, not position, so missing columns are safe).

## The right sequence

1. **Add the column to Iceberg first** using the SQL command above
2. **Then resume the consumer** — new rows with `device_os` will now write successfully
3. You do **not** need to stop the Debezium connector itself, only the Spark/Flink consumer writing to Iceberg

## Why this works

Iceberg supports schema evolution natively. When you add a column with `ALTER TABLE`, you're only changing metadata — the table's logical schema. The underlying Parquet files are unchanged. Subsequent writes include the new column; old rows read it as NULL automatically.

For the long term, if you're using CDC with Debezium, configure your connector with schema evolution handling (e.g., `schema.evolution=basic` in Debezium 2.x) so the connector notifies the schema registry of DDL changes, and the consumer can apply the corresponding Iceberg schema changes automatically or alert you to do so.

**Key point:** Iceberg's column tracking is by unique field ID (not position), so you can safely rename or reorder columns later without breaking historical data — the ID mapping stays correct.
