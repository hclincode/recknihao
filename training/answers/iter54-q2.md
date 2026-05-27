# Iter54 Q2 — Answer

**Question**: We use Debezium to capture changes from Postgres and stream them into our Iceberg tables. One of our developers just widened a column in Postgres — changed an `INT` column to `BIGINT` on the `events` table. I know adding a new column is usually fine, but a type change feels riskier. Does Debezium pick up that type change automatically and reflect it in the messages it sends downstream? And on the Iceberg side, can you actually change a column's type from INT to BIGINT without dropping and recreating the table? What breaks if we don't handle this correctly?

---

## Answer

### How Debezium detects the type change

Debezium reads Postgres's write-ahead log (WAL). When you execute `ALTER TABLE events ALTER COLUMN event_count TYPE BIGINT` in Postgres, Postgres writes a relation message to the WAL that describes the updated table structure. Debezium's Postgres source connector reads this relation message and updates its internal schema model for the `events` table.

The next row-change event (INSERT, UPDATE, or DELETE) that Debezium emits after the relation message will carry the updated schema — the field for that column will be typed as INT64 (BIGINT) in the Avro or JSON schema rather than INT32 (INT). This detection is automatic; no configuration change is needed on the Debezium source connector side.

If you are using a schema registry (Confluent Schema Registry or Apicurio), the connector will register a new schema version for the topic at this point. The schema registry is not involved in DDL detection — it only handles serialization of the Kafka message payload. DDL detection comes entirely from the WAL relation messages.

### Iceberg type widening: INT → BIGINT is supported

Iceberg has a defined set of allowed type promotions. INT → BIGINT is explicitly listed as a safe widening. You apply it with an ALTER TABLE statement:

**Trino syntax:**
```sql
ALTER TABLE iceberg.analytics.events
  ALTER COLUMN event_count SET DATA TYPE BIGINT;
```

**Spark syntax:**
```sql
ALTER TABLE iceberg.analytics.events
  ALTER COLUMN event_count TYPE BIGINT;
```

This is a metadata-only operation — Iceberg updates the schema in the table metadata without rewriting any Parquet data files. Existing Parquet files written with INT values are read correctly as BIGINT by Trino and Spark; Parquet's encoding is compatible and no backfill is needed.

### What breaks if you don't update the Iceberg schema

If BIGINT values start arriving from Debezium before you update the Iceberg schema, two failure modes are possible depending on your sink connector:

1. **Consumer fails with a type mismatch error** — the sink connector tries to write an INT64 value into an INT32 column and throws a schema error. This is the safer failure: no data corruption, just backpressure.

2. **Silent truncation** — some sink configurations will cast INT64 to INT32, silently corrupting any value larger than 2,147,483,647 (2^31 − 1). If your event counts or IDs can exceed that range, corrupted data gets written to Parquet with no error logged.

### Recommended sequence

1. Pause the Debezium consumer (or let the topic queue accumulate)
2. Apply the Iceberg ALTER TABLE to widen the column
3. Verify the schema change: `DESCRIBE iceberg.analytics.events` — confirm the column shows BIGINT
4. Resume the consumer

If you are using the Debezium Iceberg sink connector, its `schema.evolution=basic` setting can automate step 2 — when the sink connector sees a type widening in the incoming Debezium event schema, it applies the corresponding `ALTER COLUMN` to Iceberg automatically. Note that `schema.evolution=basic` is a **sink connector** setting, not a Postgres source connector setting.

### What is NOT supported

Narrowing a column type — BIGINT → INT — is rejected by Iceberg. Attempting it returns an error at the ALTER TABLE step. You cannot widen and then narrow without dropping and recreating the table. The rule is: safe promotions only (INT→BIGINT, FLOAT→DOUBLE, DATE→TIMESTAMP with caveats).
