# Iter114 Q1 — Answer

**Question**: We've had Debezium streaming our `user_profiles` Postgres table into Iceberg for about two months without issues. Last week our backend team added three new columns to `user_profiles` in Postgres — `referral_source VARCHAR`, `onboarding_step INT`, and `gdpr_consent_at TIMESTAMP` — as part of a feature release. Now I'm seeing those new columns showing up as NULL in all rows in Iceberg, even for users who signed up after the migration and definitely have values for those fields in Postgres. The Debezium connector didn't crash or log any errors — it just silently ignored the new columns. Do we need to restart the connector, or manually add the columns to the Iceberg table, or does Debezium handle schema changes automatically? And if a column was added to Postgres mid-stream, how do we backfill the historical NULLs for rows that were already in Iceberg before the new columns existed?

---

## Answer

The NULL values you're seeing are expected behavior — the new columns exist in the Debezium event envelope, but your Iceberg table and Spark consumer don't know about them yet. No data has been lost; you just need to take two steps: add the columns to Iceberg, and update your Spark consumer to pass schema changes through. Restarting the Debezium connector is NOT required and would cause it to re-read events from the last committed offset.

### Why the New Columns Are NULL

Debezium detected the schema change automatically (via the `schema_history` topic it maintains) and is already including `referral_source`, `onboarding_step`, and `gdpr_consent_at` in the CDC event envelopes it writes to Kafka. However, the problem is on the consumer side:

1. **The Iceberg table schema doesn't have the new columns.** Iceberg is schema-on-write: if a column doesn't exist in the table, the Spark streaming job silently drops it rather than failing.
2. **The Spark consumer may be using a fixed schema** (hardcoded `StructType`) instead of reading the schema from the Debezium envelope dynamically.

### Step 1: Add Columns to the Iceberg Table (Metadata-Only, Instant)

Iceberg schema evolution is metadata-only — existing rows are not rewritten. Old rows will show NULL for the new columns (which is correct, since those values didn't exist when those rows were written).

```sql
-- In Trino — all three are metadata-only operations, no data rewrite
ALTER TABLE iceberg.analytics.user_profiles
ADD COLUMN referral_source VARCHAR;

ALTER TABLE iceberg.analytics.user_profiles
ADD COLUMN onboarding_step INTEGER;

ALTER TABLE iceberg.analytics.user_profiles
ADD COLUMN gdpr_consent_at TIMESTAMP(6);
```

These operations are safe to run while the streaming job is running. Existing rows return NULL for the new columns; new rows written after this point can carry the values.

**What Iceberg schema evolution does NOT handle automatically:**
- Column renames — must be done explicitly with `ALTER TABLE ... RENAME COLUMN`
- Type changes (e.g., VARCHAR → TEXT) — must use `ALTER TABLE ... ALTER COLUMN ... TYPE`
- Column drops — must be explicit; Iceberg marks them as optional/dropped
- NOT NULL constraints — Iceberg columns are always nullable

### Step 2: Enable Schema Merge in the Spark Consumer

Your Spark Structured Streaming job must be configured to accept new columns from the Debezium envelope. Two settings are required — **both** are needed; either one alone is insufficient:

```python
spark.sql("""
    ALTER TABLE iceberg.analytics.user_profiles
    SET TBLPROPERTIES ('write.spark.accept-any-schema' = 'true')
""")
```

And in the Spark write operation:

```python
# In your Structured Streaming forEachBatch or writeStream:
df.writeTo("iceberg.analytics.user_profiles") \
  .option("mergeSchema", "true") \
  .append()
```

Without `write.spark.accept-any-schema=true`, Spark rejects any write that doesn't exactly match the current table schema (even if it's a new nullable column). Without `.option("mergeSchema", "true")`, Spark silently drops columns that aren't in the table schema.

### Step 3: Backfill the New Columns for Post-Release Rows

You said users who signed up after the release have NULL values in Iceberg even though their data is in Postgres. This means the columns were being silently dropped at write time (Step 2 was not configured). Now that the columns are in the Iceberg table and `accept-any-schema` is enabled, new events flowing through will populate correctly. But existing rows for post-release users need to be backfilled.

Backfill from the Postgres primary using a MERGE INTO:

```python
from pyspark.sql.functions import col

# Read only the affected columns from Postgres primary for users created after the release
backfill_df = spark.read.jdbc(
    url=PG_PRIMARY_URL,
    table="""(
        SELECT user_id, referral_source, onboarding_step, gdpr_consent_at
        FROM user_profiles
        WHERE created_at >= '2026-05-18'   -- date of the migration
    ) t""",
    properties={"driver": "org.postgresql.Driver", **PG_PROPS},
)

backfill_df.createOrReplaceTempView("user_profiles_backfill")

spark.sql("""
    MERGE INTO iceberg.analytics.user_profiles t
    USING user_profiles_backfill s
    ON t.user_id = s.user_id
    WHEN MATCHED THEN UPDATE SET
        t.referral_source   = s.referral_source,
        t.onboarding_step   = s.onboarding_step,
        t.gdpr_consent_at   = s.gdpr_consent_at
""")
```

Note: `WHEN NOT MATCHED THEN INSERT *` is intentionally omitted. The goal is to backfill only columns — not insert rows that the streaming pipeline hasn't seen yet (doing so could create duplicates when the CDC events for those rows eventually arrive).

### What About Pre-Release Rows?

Rows created before the three columns were added to Postgres genuinely have no values for those fields — NULL is correct for them. You don't need to backfill those rows. If a business requirement needs a default value (e.g., `onboarding_step = 0` for legacy users), use a MERGE:

```sql
-- Optional: fill legacy rows with a business-appropriate default
MERGE INTO iceberg.analytics.user_profiles t
USING (
    SELECT user_id FROM iceberg.analytics.user_profiles
    WHERE onboarding_step IS NULL
) s
ON t.user_id = s.user_id
WHEN MATCHED THEN UPDATE SET t.onboarding_step = 0;
```

### Summary

| Step | Action | Required? |
|---|---|---|
| Add columns to Iceberg | `ALTER TABLE ... ADD COLUMN` (×3) | Yes — do first |
| Enable schema merge | `write.spark.accept-any-schema=true` + `mergeSchema=true` | Yes — both required |
| Backfill post-release rows | MERGE from Postgres primary | Yes — for rows already missed |
| Backfill pre-release rows | Set business-default values | Optional / business decision |
| Restart Debezium connector | — | No — not needed |

The Debezium connector itself does not need to be restarted. It is already streaming the new columns in the event envelopes. The fix is entirely on the consumer side (Iceberg schema + Spark write configuration).
