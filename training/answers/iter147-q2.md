# Iter 147 Q2 — Iceberg ADD COLUMN Schema Evolution

## Answer

When you run `ALTER TABLE ADD COLUMN` on an Iceberg table, it is a **metadata-only operation**. It doesn't rewrite any existing Parquet files and completes in milliseconds. Both Trino and your Spark batch job will work fine with the schema change. Old Parquet files written before the column existed will NOT break.

### How Iceberg schema evolution works

Iceberg tracks every column by a numeric field ID, not by name or position. When you add a column, Iceberg assigns a new unique field ID and updates only the table metadata in the Hive Metastore. The existing Parquet files on MinIO are untouched.

When a data file was written before a column ID existed, Iceberg automatically returns NULL for that column when reading old files. This is not a bug — it is by design. New columns added to Iceberg are always nullable, regardless of what you declare in the ALTER statement. This is intentional: historical rows genuinely have no value for the new column, so claiming NOT NULL would be incorrect.

### What happens to your specific setup

**When you run ADD COLUMN:**

```sql
-- Run from Trino — same syntax works in Spark SQL
ALTER TABLE iceberg.analytics.your_table ADD COLUMN new_column_name VARCHAR;
```

This:
1. Assigns a new column ID in the Iceberg metadata
2. Updates the table schema in the Hive Metastore
3. Completes in milliseconds — no data movement

**Old Parquet files** (written before ADD COLUMN): when Trino dashboards or the Spark batch job read them, rows in those files return NULL for `new_column_name` because the column ID was not in the file when it was written. No parsing errors, no schema mismatch failures.

**New Parquet files** (written after ADD COLUMN): rows include the new column with actual values.

**Your Spark batch job**: continues to work without any changes. Iceberg handles schema evolution transparently. Spark uses snapshot isolation — when the hourly job starts, it attaches to a specific snapshot. Schema changes create new snapshots, but in-flight jobs keep reading their original snapshot. After the schema evolves, the next batch run sees the new column and includes it in writes automatically.

**Trino dashboards**: continue to work. A `SELECT new_column_name FROM your_table` query returns actual values from new files and NULL from old files — which is the correct and expected behavior.

### The safe procedure for production

No downtime is required. Queries and ingestion can keep running.

**Step 1**: Run the ADD COLUMN — it is safe to do immediately:

```sql
ALTER TABLE iceberg.analytics.your_table 
ADD COLUMN new_column_name VARCHAR;
```

**Step 2** (optional): If you want historical rows to have a non-NULL value, backfill with a Spark job:

```python
df = spark.sql("""
    SELECT *, 'default_value' AS new_column_name 
    FROM iceberg.analytics.your_table
    WHERE new_column_name IS NULL
""")
df.writeTo("iceberg.analytics.your_table").overwritePartitions()
```

**Step 3**: Update your ingestion pipeline to write values for the new column in the next Spark batch run. No special restart or coordination needed.

### Important caveats

**Nullability**: New columns in Iceberg 1.5.2 are always nullable, even if you write `ADD COLUMN new_col VARCHAR NOT NULL`. If a downstream dashboard assumes the column is never NULL, either backfill historical partitions with a sensible default, or document the cutover date and filter dashboards to exclude pre-cutover rows.

**No "schema mismatch" Spark errors**: Spark's Iceberg integration reads the current table schema at the start of each job and handles old files with missing columns via the field ID mechanism. You will not see `AnalysisException: cannot resolve column` or similar errors.

**DROP COLUMN and RENAME COLUMN behave differently** — those operations have more complex implications (particularly for Debezium CDC), but ADD COLUMN is the safest schema change you can make on a live Iceberg table.

### Summary

| Concern | Reality |
|---|---|
| Old Parquet files break? | No — Iceberg returns NULL for the new column in old files |
| Spark job fails with schema mismatch? | No — Iceberg handles mixed-schema files transparently |
| Need to take dashboards or ingestion down? | No — ADD COLUMN is a metadata-only, instant operation |
| Historical rows have NULL for new column? | Yes — this is correct. Backfill if you need non-NULL values |
| Need to restart Spark batch job? | No — next scheduled run automatically includes the new column |

Run the `ALTER TABLE ADD COLUMN` now without worrying about breaking old files or running jobs. If you want historical rows to have a non-NULL default, run a Spark backfill job after.
