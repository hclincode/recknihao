# Answer to Q1: Schema Evolution Mid-CDC-Pipeline — ADD COLUMN in Postgres (Iter 318)

This is a classic schema-evolution trap in CDC pipelines. You're seeing exactly the expected behavior — the problem isn't in Debezium, it's in the Iceberg consumer.

## What Debezium did correctly

Yes, Debezium automatically picks up new columns. When the `ALTER TABLE ... ADD COLUMN` ran on Postgres, it became visible via logical replication WAL. On the next INSERT or UPDATE after the DDL, Postgres's WAL emitted a RELATION message describing the new column layout. Debezium read that and immediately started emitting the new columns in subsequent Kafka events. This happens without any connector restart or config change — that's why your downstream consumers already see the new columns in the Kafka messages.

**Debezium is working correctly. The problem is on the consumer (Iceberg) side.**

## Why the columns aren't in the Iceberg table

Your Spark consumer's MERGE INTO is trying to write rows that include the new columns, but the Iceberg table schema doesn't know about them yet. Two common outcomes:

**Outcome 1 — Silent NULL drop (what you're likely experiencing):**
If your MERGE statement uses an explicit column list — e.g., `INSERT (id, tenant_id, user_id, event_name, ...)` listing only the old columns — the new column is silently dropped at the Spark DataFrame mapping stage. The row lands in Iceberg, but without those columns. No error is raised. This is the most dangerous failure mode.

**Outcome 2 — AnalysisException:**
If your MERGE uses wildcard or dynamic column matching, Spark throws `AnalysisException: Unable to find the column ... of the target table from the INSERT columns`. You'd see this in Spark logs and the streaming batch would not commit.

Since rows are landing (just without the new columns), you're in Outcome 1 — explicit column list, silent drop.

## The fix: pause-ALTER-resume sequence

1. **Pause your Spark consumer** — stop the Structured Streaming job. Kafka retains the buffered events; they're safe within your retention window.

2. **Add the columns to the Iceberg table** (metadata-only, instant):
   ```sql
   ALTER TABLE iceberg.analytics.events ADD COLUMN new_col VARCHAR;
   ALTER TABLE iceberg.analytics.events ADD COLUMN other_new_col VARCHAR;
   ```
   Iceberg adds columns as nullable. Historical rows before the ADD COLUMN will have NULL — there's no way to backfill them from the CDC stream since those events have already been consumed and committed. If you need historical values, you'd need a separate Postgres backfill job.

3. **Resume the consumer** — restart the Spark job from its last checkpoint. Buffered Kafka events flow through the MERGE, which now succeeds because the target columns exist.

Total downtime: 30–60 seconds.

## Fix the root cause: remove explicit column lists

Check your MERGE statement. If it lists columns explicitly, update it to use wildcard syntax:

```sql
-- Bad: explicit column list will silently drop new columns
MERGE INTO iceberg.analytics.events t
USING source s ON t.id = s.id
WHEN MATCHED THEN UPDATE SET t.col1 = s.col1, t.col2 = s.col2   -- misses new columns
WHEN NOT MATCHED THEN INSERT (id, col1, col2) VALUES (s.id, s.col1, s.col2)

-- Better: dynamic schema matching (Iceberg 1.5.2 + Spark)
MERGE INTO iceberg.analytics.events t
USING source s ON t.id = s.id
WHEN MATCHED THEN UPDATE SET *
WHEN NOT MATCHED THEN INSERT *
```

Using `*` means the MERGE automatically picks up new Iceberg columns without any code change.

## What about rows that already landed without the new columns?

Those rows exist in Iceberg with NULL for the new columns. The only way to fix them is a Postgres backfill:

```python
# Read the affected time window from Postgres
df = spark.read.jdbc(
    url=PG_URL,
    table=f"(SELECT * FROM events WHERE created_at >= '{alter_table_time}') t",
    properties=PG_PROPS
)
# Merge into Iceberg to fill in the missing column values
df.writeTo("iceberg.analytics.events").option("mergeSchema", "true").append()
```

Or use a MERGE INTO to update existing rows rather than appending duplicates.

## Don't restart Debezium

The connector is working correctly. All remediation belongs on the consumer + Iceberg side. Restarting the connector would trigger a re-snapshot (or skip from current position depending on `snapshot.mode`), neither of which helps with the Iceberg schema lag.
