# Iter141 Q2 — Answer

**Question**: "One of our backend engineers added a new nullable column to a Postgres table we're streaming into Iceberg via Debezium. The column appeared in Postgres with a default value and everything looks fine on the Postgres side. But now I'm seeing some weirdness in our pipeline — some rows landing in Iceberg have the new column populated and some don't, and I'm not totally sure if Debezium even picked up the schema change automatically or if we needed to do something. What actually happens when you add a column to a Postgres table that Debezium is already streaming from, and do we need to take any manual steps to make sure the Iceberg table ends up with consistent data?"

---

## What Debezium Does Automatically

Debezium picks up the Postgres schema change automatically — **no connector restart or manual action on the Debezium side is needed.**

When your engineer ran `ALTER TABLE ... ADD COLUMN` in Postgres, the DDL was written to the WAL. On the first DML statement (INSERT, UPDATE, or DELETE) against the table *after* the column was added, Postgres emits an updated RELATION message in the WAL that describes the new column layout. Debezium reads this RELATION message, updates its in-memory schema, and from that point forward all change events include the new column in the `after` struct.

**The result**: Kafka events now have the new column in their schema. Events written before the DDL don't include it (NULL). Events written after do.

---

## Why Some Rows Have the Column and Some Don't

This is expected behavior — not a bug:

**Rows written BEFORE the column was added** → NULL in Iceberg. Postgres doesn't retroactively write new-column values into the WAL for pre-existing rows. Debezium captures these as NULL in the `after` struct.

**Rows written AFTER the column was added** → populated with the actual value (or NULL if the application explicitly wrote NULL).

So the inconsistency you're seeing is correct: the column exists for all rows in the Iceberg schema, but only rows written post-DDL have non-NULL values for it.

---

## The Step You Likely Missed: Updating the Iceberg Table Schema

The Iceberg target table must have the column added before the pipeline tries to write rows containing it. If the column is missing from the Iceberg schema when the first Kafka event with the new column arrives, one of two things happens:

- **Pipeline stalls with `AnalysisException`**: Spark's MERGE INTO sees a column in the source DataFrame that the target table doesn't have and throws an error. The batch fails, the Kafka offset doesn't commit, and subsequent batches retry with the same error.
- **Column silently dropped**: If your Spark writer uses schema inference or `mergeSchema=false`, the new column may be silently discarded — rows land without the new field.

---

## The Correct Sequence

**Step 1: Pause the Spark consumer** (Debezium keeps running and buffers events in Kafka — no data is lost)

```bash
kubectl scale deployment spark-events-consumer --replicas=0
```

**Step 2: Add the column to Iceberg** (metadata-only, instant)

```sql
-- Trino 467
ALTER TABLE iceberg.analytics.events ADD COLUMN new_col VARCHAR;
```

Iceberg always adds columns as NULLABLE — old Parquet files don't contain the column, so they return NULL. This is correct behavior.

**Step 3: Update your Spark consumer's schema definition** to include the new field

If you hardcoded the `after` struct schema in your Spark job, add the new field:

```python
after_schema = StructType([
    StructField("event_id",    StringType()),
    StructField("user_id",     StringType()),
    # ... existing fields ...
    StructField("new_col",     StringType()),   # ← add this
])
```

**Step 4: Resume the Spark consumer**

```bash
kubectl scale deployment spark-events-consumer --replicas=1
```

The consumer resumes from its last committed Kafka offset (stored in the Spark streaming checkpoint), reads buffered events including the new column, and MERGE INTO writes them correctly into Iceberg.

**Total downtime**: under 60 seconds (bottleneck is pod startup; the ALTER TABLE is milliseconds).

---

## Backfilling Old Rows (Optional)

After the pipeline is running, historical rows in Iceberg have NULL for the new column. If you need non-NULL values for historical data (for dashboards that require the column):

```sql
-- Spark SQL: backfill historical rows with a default or computed value
MERGE INTO iceberg.analytics.events t
USING (
    SELECT event_id, 'default_value' AS new_col
    FROM iceberg.analytics.events
    WHERE new_col IS NULL
) s
ON t.event_id = s.event_id
WHEN MATCHED THEN UPDATE SET t.new_col = s.new_col;
```

Or, if the value can be derived from another column:

```sql
UPDATE iceberg.analytics.events
SET new_col = CAST(some_other_col AS VARCHAR)
WHERE new_col IS NULL;
```

Only backfill if your dashboards actually need historical non-NULL values. If the column is only meaningful for future rows (e.g., a feature flag that didn't exist before), leave historical rows as NULL.

---

## What NOT to Do

**Do NOT restart the Debezium connector.** A restart is unnecessary and risky:
- With `snapshot.mode=initial` (the default): restart triggers a full table re-snapshot, flooding Kafka with 3 months of events and causing millions of duplicates in Iceberg.
- With `snapshot.mode=never`: restart is safe but still unnecessary.

Debezium already picked up the schema change automatically from the WAL. Restarting only introduces risk.

---

## Why the "Weirdness" Is Actually Correct

Your observation — some rows have the new column, some don't — is exactly right. The pipeline is working:
1. Debezium updated its schema from the WAL RELATION message.
2. Events after the DDL include the new column.
3. Events before the DDL don't (NULL).
4. If the Iceberg column was added before those events arrived, they landed correctly.

The only manual steps needed are on your side of the pipeline: (1) add the column to Iceberg, and (2) update the Spark consumer schema. Debezium handles itself.

---

## Summary

| Layer | What happens on ADD COLUMN | Manual action needed? |
|---|---|---|
| Postgres | Column added with default for future rows; existing rows are NULL | None |
| Debezium | Reads RELATION message on next DML; auto-updates schema | None |
| Kafka | Change events include new column from first post-DDL event | None |
| Spark consumer | May fail or drop new column if schema isn't updated | Yes — update hardcoded schema |
| Iceberg table | Must have column added before Spark tries to write it | Yes — `ALTER TABLE ADD COLUMN` |
| Historical rows | NULL for all rows written before the DDL | Optional — backfill if needed |
