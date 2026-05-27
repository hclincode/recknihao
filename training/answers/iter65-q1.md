# Iter65 Q1 — Answer

**Question**: We ingest from Postgres into Iceberg every night using a Spark job. Last week, a backend engineer added a new column to one of our Postgres source tables — just a new nullable text field — without telling the data team. When our ingestion job ran, it broke because the schema it was writing to Iceberg no longer matched what was coming from Postgres. We had to manually fix it and re-run. What is the right way to handle this? Is there a way to set up the ingestion so that when a new column shows up in Postgres, it either gets picked up automatically without breaking everything, or at least fails with a clear error instead of corrupting data? And if the Iceberg table already has months of historical data, does adding a new column to it cause any problems for the old rows?

---

## Answer

The right way to handle schema changes depends on which Spark ingestion pattern you're using. The answer to "what happens to old rows" is straightforward: adding a new column to Iceberg is safe for historical data. But the answer to "how do you prevent the next break" requires you to know your pattern first.

### How to prevent the break in the future

Your first step is to identify whether your ingestion job uses one of these patterns:

1. **Pattern A — Full-refresh** (you read the entire Postgres table every night and replace the Iceberg table with `createOrReplace()`)
2. **Pattern B — Incremental append** (you read only new/changed rows since the last run using a watermark and call `.append()`)
3. **Pattern C — CDC** (you use Debezium and Kafka to stream row changes)

The fix is fundamentally different for each pattern.

#### If you use Pattern B (incremental append) — most common

This is the most common setup for SaaS analytics. Your job reads something like:

```python
df = spark.read.jdbc(..., table=f"(SELECT * FROM events WHERE updated_at > '{last_ts}') t", ...)
df.writeTo("iceberg.analytics.events").append()
```

When a new column appears in Postgres:

1. **Manually add the column to Iceberg** (one-time fix):
   ```sql
   ALTER TABLE iceberg.analytics.events ADD COLUMN new_field VARCHAR;
   ```
   This is **metadata-only** — no data rewrite. It runs in milliseconds even on a 10 TB table.

2. **Update your Spark job's SELECT list** (code fix):
   If your JDBC read uses `SELECT *`, it picks up the new column automatically. If you use an explicit column list, add the new column to it.

3. **Re-run the job.** New rows will have the actual value; old rows return `NULL` for the new column when queried.

That's it. Iceberg's schema evolution is column-name-based, not position-based, so old Parquet files don't break when you add a column — Iceberg fills in `NULL` for missing columns on read.

**To prevent waiting until a column breaks the job:** Add a schema-diff check at the start of your Spark job that compares Postgres's column list to Iceberg's and alerts you before running.

#### If you use Pattern A (full-refresh with createOrReplace())

With `createOrReplace()`, the Spark job's DataFrame **IS** the table schema. Each run, the entire Iceberg table is dropped and rebuilt from the DataFrame.

**Do NOT run `ALTER TABLE ... ADD COLUMN`.** The next time your job runs, `createOrReplace()` wipes the table and recreates it from your DataFrame's schema. If the DataFrame doesn't include the new column, the column vanishes silently. This is the exact silent-data-loss bug you want to avoid.

Instead:
1. **Update the Spark job's JDBC SELECT** to include the new column.
2. **Re-run the job.** The table is recreated with the new column because the DataFrame now has it.
3. **Test locally before deploying** — the job is responsible for the schema, so any schema change requires a code change.

#### If you use Pattern C (CDC with Debezium)

If you're using the Debezium Iceberg sink connector, set `schema.evolution=basic` in the connector config. The sink connector automatically detects new columns in Kafka messages and runs `ALTER TABLE ... ADD COLUMN` on Iceberg without manual intervention.

### What happens to old rows when you add a new column to Iceberg

**Short answer: nothing bad.** Old rows are safe.

When you run `ALTER TABLE iceberg.analytics.events ADD COLUMN new_field VARCHAR`, Iceberg **does not rewrite any data files.** This is a pure metadata change. The old Parquet files on MinIO still don't have the new column — they're unchanged. When Iceberg queries them, it silently returns `NULL` for the new column on rows from those old files, just like it does for any missing data.

Example:
- May 1: you load 1M rows into Iceberg. They don't have `new_field` because it didn't exist yet.
- May 8: the Postgres engineer adds `new_field` to the source table.
- You run `ALTER TABLE iceberg.analytics.events ADD COLUMN new_field VARCHAR`.
- May 9 and beyond: new rows from Postgres have a real `new_field` value.
- Queries still work correctly: the 1M rows from May 1 return `NULL` for `new_field`; rows after May 8 return the actual value.

This is Iceberg's core schema-evolution guarantee — it's safe to add columns.

### The pragmatic fix: set up a pre-flight schema check

Don't wait for the 2 AM alert. At the start of your Spark ingestion job, add a function that:

1. Reads Postgres's `information_schema.columns` to get its current column list.
2. Runs `DESCRIBE TABLE iceberg.analytics.events` to get Iceberg's column list.
3. Compares them.
4. If new columns exist, **alert** instead of running silently. For Pattern B / incremental jobs, you can optionally auto-apply `ALTER TABLE ADD COLUMN` and continue. For Pattern A / full-refresh jobs, **fail loudly** and require a code change.

Here is a complete Python function you can add to your Spark job:

```python
def check_schema_drift(spark, pg_url, pg_props, pg_table, iceberg_table):
    """
    Compare Postgres and Iceberg column lists.
    Returns (new_cols, dropped_cols) — lists of column names that differ.
    Raises RuntimeError if new columns are found (caller decides how to handle).
    """
    pg_cols_df = spark.read.format("jdbc") \
        .option("url", pg_url) \
        .option("dbtable", f"""
            (SELECT column_name
             FROM information_schema.columns
             WHERE table_name = '{pg_table}'
             ORDER BY ordinal_position) t
        """) \
        .options(**pg_props).load()
    pg_cols = {row.column_name for row in pg_cols_df.collect()}

    iceberg_cols = {f.name for f in spark.table(iceberg_table).schema.fields}

    new_in_pg = pg_cols - iceberg_cols
    dropped_in_pg = iceberg_cols - pg_cols

    if new_in_pg:
        raise RuntimeError(
            f"Schema drift detected: Postgres has new columns {new_in_pg}. "
            f"Run ALTER TABLE {iceberg_table} ADD COLUMN ... for each, then re-run the job."
        )
    return new_in_pg, dropped_in_pg
```

Wire this in as the first call in your job's main function, before any JDBC read. The job now fails loudly with a descriptive error instead of silently corrupting data or crashing mid-run.

### Why did your job break in the first place

The exact failure mode depends on your pattern, but the common cases are:

- **Pattern B (append)**: If your JDBC SELECT used an explicit column list, the new column was silently ignored. Or, if your Iceberg table's schema was strictly defined and you tried to append a DataFrame with an unexpected extra column, Spark errored with a schema-mismatch error.
- **Pattern A (full-refresh)**: The new column appeared in Postgres. The DataFrame reflected it (because `SELECT *` picked it up). The Iceberg table schema changed, but your job might have expected a stable schema.

In both cases, the fix was manual because there was no prevention mechanism. A pre-flight schema check prevents the next incident.

---

## Summary

- **Add the column to Iceberg** (Pattern B): `ALTER TABLE ... ADD COLUMN` — metadata-only, no data rewrite.
- **Update your Spark job** (Pattern A): edit the JDBC SELECT or DataFrame schema — the job owns the schema.
- **Old rows are safe**: adding a column doesn't touch existing data. Old rows return `NULL` for the new column.
- **Prevent the next break**: add a pre-flight schema-diff check at the start of your job that alerts (or fails loudly) when Postgres and Iceberg schemas diverge.
