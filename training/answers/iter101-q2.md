# Iter101 Q2 — Answer

**Question**: We added a new column to one of our Postgres source tables last week — just a nullable varchar column for some optional metadata. Debezium has been running CDC on that table continuously for months. I noticed our Iceberg table doesn't seem to have the new column showing up in queries. What actually happens on the Debezium/Iceberg side when you add a column to the Postgres source table mid-stream, and what do we need to do to get that new column propagating correctly?

---

## Answer

You're dealing with a classic CDC schema-evolution mismatch. Debezium is working correctly. The issue is that Iceberg doesn't automatically add columns just because Debezium is sending them. Here's what's happening at each layer and the exact fix.

### What Debezium does when Postgres gets a new column

**Debezium does not directly detect DDL statements.** When `ALTER TABLE your_table ADD COLUMN metadata_note VARCHAR` ran, that statement itself did not flow to Debezium.

Instead, Debezium uses the WAL:

1. After the ALTER runs, Postgres continues normally.
2. The **next time anyone writes a row** (INSERT, UPDATE, or DELETE), the WAL includes an updated **relation message** — a table structure descriptor saying "this table now has these columns: [old cols] + [new col]."
3. Debezium reads that relation message and learns about the new column. From that moment, all Kafka messages include the `metadata_note` field (with null values for rows that never got a new write).

**The timing trap**: If nobody writes to the table after the ALTER, Debezium keeps publishing events with the old schema. The new column is invisible in Kafka until the first INSERT or UPDATE hits the table.

### Why the Iceberg table doesn't have the column

Debezium is publishing `metadata_note` to Kafka — but Iceberg isn't accepting it automatically.

**For a Spark Structured Streaming consumer** (reading from Kafka, writing to Iceberg via MERGE INTO or append):

Iceberg enforces strict schema matching by default. If the incoming DataFrame contains a column (`metadata_note`) that doesn't exist in the Iceberg table schema, the write is **rejected**. You'll see a schema mismatch error in Spark logs. The rows are never written, the column data is lost, and the table schema stays unchanged.

**For the debezium-server-iceberg sink** (direct Postgres → Iceberg without Spark):

The sink has `debezium.sink.iceberg.allow-field-addition`, which **defaults to `false`**. With `false`, the sink rejects writes containing new fields. With `true`, it auto-runs `ALTER TABLE ADD COLUMN` when it sees a new field in the Kafka message.

### The fix: three steps

**Step 1: Add the column to Iceberg manually.**

Run this in Trino or Spark — it's a metadata-only operation (no data rewrite, completes in milliseconds):

```sql
ALTER TABLE iceberg.analytics.your_table
ADD COLUMN metadata_note VARCHAR;
```

Iceberg's schema-evolution guarantee: **all existing rows immediately return NULL for the new column when queried** — no backfill job needed.

**Step 2: Resume your pipeline.**

- **Spark consumer**: If the job crashed or paused on a schema-mismatch error, restart it. It picks up from where it left off in Kafka and starts writing `metadata_note` successfully.
- **debezium-server-iceberg**: The sink should resume automatically. Optionally, enable auto-evolution in your config to prevent this manual step next time:
  ```properties
  debezium.sink.iceberg.allow-field-addition=true
  ```
  (This only applies to the standalone debezium-server-iceberg sink, not Spark consumers.)

**Step 3: Verify.**

```sql
SELECT metadata_note FROM iceberg.analytics.your_table LIMIT 10;
```

Old rows: NULL. Rows written after the ALTER: real values (or NULL if Postgres has NULL there).

### What happens to historical rows

Old Parquet files on MinIO don't physically contain `metadata_note` bytes. When Iceberg reads those files, it checks the table schema, sees `metadata_note` is a column, and fills in NULL for missing fields automatically. No backfill job needed.

- Old rows → `metadata_note = NULL`
- New rows (after the ALTER) → `metadata_note = <value from Postgres>`

### REPLICA IDENTITY — nothing special needed

The new column requires no special Postgres config. If you already set `REPLICA IDENTITY FULL` for this table when you set up CDC, the new column is automatically included in UPDATE/DELETE before-images. No reconfiguration needed.

If you never set `REPLICA IDENTITY FULL`:

```sql
ALTER TABLE your_table REPLICA IDENTITY FULL;
```

This ensures Debezium's `before` field contains all columns (not just PKs) for DELETE/UPDATE events — important for audit use cases.

### Common gotchas

1. **Table received no writes after the Postgres ALTER.** Debezium never sees the relation message. Force a test write: `UPDATE your_table SET metadata_note = NULL WHERE id = 1` to trigger Debezium to learn about the schema change.

2. **Debezium publishes the column, but Iceberg silently rejected it.** Look for schema-mismatch errors in your Spark consumer logs (not Debezium logs). The job may be paused.

3. **Using `MERGE INTO` in Spark.** MERGE pushes `metadata_note` correctly once the Iceberg schema includes it — but you must run `ALTER TABLE ADD COLUMN` before resuming, not after.

4. **Column added but old queries still show nothing.** Likely Trino metadata cache. Wait 60 seconds and re-query, or invalidate the cache.

### Prevention for next time

- After adding a Postgres column, trigger at least one write to the table so Debezium detects the change immediately.
- Monitor the Kafka topic with `kafka-console-consumer` to confirm `metadata_note` appears in the JSON payloads before assuming Debezium sent it.
- Run `ALTER TABLE ADD COLUMN` in Iceberg as soon as you see the new field in Kafka — before your consumer errors out.
- If using debezium-server-iceberg, enable `allow-field-addition=true` for automatic column propagation.

### The mental model

**Debezium detects Postgres schema changes via WAL and publishes them to Kafka. Iceberg does not consume those schema changes automatically.** You (or debezium-server-iceberg with the right config) must explicitly run `ALTER TABLE ADD COLUMN`. Without it, Iceberg rejects writes containing the new field — Debezium is sending the data, Iceberg is dropping it, and the new column's values are lost silently.
