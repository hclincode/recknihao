# Answer to Q2: INT → BIGINT Column Type Change Through Debezium CDC (Iter 346)

You're in a **different and more dangerous situation** than just adding a new column. Column type changes require explicit handling on both the Debezium and Iceberg sides. Iceberg does NOT automatically handle type changes the way it handles new columns.

## What Debezium does when the type changes

**Debezium picked up the change correctly** — that part worked. Here's what happened:

1. Someone ran `ALTER TABLE your_table ALTER COLUMN some_id TYPE BIGINT` in Postgres.
2. Postgres updated the column type — `INT` to `BIGINT` is a metadata-only change in Postgres, because any 32-bit int value fits fine in a 64-bit slot.
3. The next `INSERT`, `UPDATE`, or `DELETE` on that table produced a **WAL RELATION message** — a schema announcement inline with the row change. Debezium read that and updated its in-memory schema.
4. From that point forward, **every event Debezium emits includes the column as `BIGINT`**.

## Where the danger is: your Iceberg table

**Iceberg does NOT automatically apply the type change.** Your Iceberg table schema is still `INT`, but Debezium is sending events typed as `BIGINT`.

When your Spark writer tries to `MERGE INTO` the Iceberg table with the new events:

- **If the writer is configured strictly** (the default): Spark throws an `AnalysisException` saying "schema mismatch — source has BIGINT but target has INT" and the streaming batch fails. No data is written until you fix the schema.
- **If the writer has auto-schema-evolution enabled**: behavior is unpredictable — you might get silent errors, data loss, or NULL values where the BIGINT events should land.

## What you need to check right now

1. **Look at your Spark streaming job logs** for `AnalysisException`, `schema mismatch`, or `Unable to find the column` errors. If these are appearing, your pipeline is blocked and has been failing since the type change hit.

2. **Check the Iceberg table schema** from Trino:
   ```sql
   DESCRIBE TABLE iceberg.analytics.your_table;
   -- Is the column still INT or already BIGINT?
   ```

3. **Verify Debezium is sending the new type** — check a recent Kafka message from the topic to confirm the field is present as BIGINT.

## The fix (straightforward — INT to BIGINT is safe)

`INT` to `BIGINT` is a widening promotion — the safest possible type change. Iceberg supports this as a metadata-only operation:

From Trino:
```sql
ALTER TABLE iceberg.analytics.your_table ALTER COLUMN some_id SET DATA TYPE BIGINT;
```

From Spark SQL:
```sql
ALTER TABLE iceberg.analytics.your_table CHANGE COLUMN some_id some_id BIGINT;
```

**This is metadata-only** — no Parquet files are rewritten, no data is changed, it completes in milliseconds even on a multi-terabyte table.

After you run this, pause and resume your Spark streaming consumer (or let it auto-recover on the next batch). New events with the BIGINT type will now write successfully.

## What to check for damage

If the pipeline was blocked for a while, you may have a gap in your data.

1. **Check how long the error lasted** by reviewing your Spark job logs. Note the timestamp when the first schema-mismatch error appeared.
2. **Check Debezium's consumer group lag** in Kafka — if it's very high, the connector has been buffering events. That's a good sign; you haven't lost the events, they're backed up in Kafka (7-day default retention).
3. **After fixing the Iceberg schema and restarting Spark**, monitor the first few batches to ensure events are writing. Check row counts before/after to confirm there's no gap.

## Why this is more dangerous than adding a column

- **Added column**: Iceberg automatically assigns a new field ID. Old rows return NULL. Safe, automatic, no blocking.
- **Type change on existing column**: Iceberg must change the registered type in metadata, which affects every reference to that column. Not automatic — you must do it intentionally. Widening promotions (INT → BIGINT, FLOAT → DOUBLE) are still metadata-only because the binary representation stays compatible.
- **Narrowing type changes** (BIGINT → INT) or **cross-type changes** (INT → STRING) are **not supported** in Iceberg 1.5.2. You'd have to create a new table with a different column name and backfill.

The good news: `INT` to `BIGINT` is the safest type change possible. You have no data corruption risk — it's purely a metadata fix, and the events are waiting in Kafka for you.

**Resources cited:** `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md`
