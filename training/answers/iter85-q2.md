# Iter85 Q2 — Answer

**Question**: Adding a new column to Postgres source table while incremental JDBC+MERGE sync is running. Does new column auto-appear in Iceberg? Does sync fail or silently drop data? How to migrate safely without downtime?

---

## Answer

Great question — this is one of the highest-risk moments in an incremental pipeline, and the default behavior isn't intuitive. Let me walk through exactly what happens and how to do it safely without downtime.

### The Default Behavior: It Fails, Not Silently

When someone adds a new column to Postgres and your JDBC job runs, the sync job **fails with a schema mismatch error**. It does NOT silently drop the new data, and it does NOT automatically accept it into Iceberg. Iceberg's default is deliberately conservative — it refuses to write a DataFrame that contains columns the table's schema doesn't expect. This is the safety property: it prevents accidental schema drift from corrupting production tables.

So if your `SELECT *` from Postgres picks up the new column, the job stops with an exception mentioning something like "extra columns in source dataframe." No rows are written. No silent data loss.

### The Safe Migration Path: No Downtime Required

Here's the correct sequence — **you do NOT need to pause ingestion**:

**Step 1: Add the column to Iceberg FIRST (metadata-only — takes milliseconds)**

```sql
ALTER TABLE iceberg.analytics.events ADD COLUMN new_column_name STRING;
```

This is a pure metadata operation. No Parquet files are rewritten, no data moves, no downtime. Even on a 10 TB table, it completes in milliseconds. Iceberg tracks columns by ID internally, so it can retroactively fill NULL for missing columns in old data files when they're queried.

**Step 2: Re-run your sync job**

Once the Iceberg schema includes the new column, your Spark job runs normally. Old rows that synced before the column existed will transparently return NULL when the new column is queried — no backfill needed.

**Why this order matters:** If you try to add the column in Iceberg *after* the job runs with the new column in the DataFrame, the job will have already failed and data is stuck. Always alter the Iceberg table first, then deploy the job update.

### The Two Auto-Evolution Knobs (Why We Don't Use Them in Production)

Iceberg does support automatic schema evolution — if a column exists in your DataFrame but not the table, Iceberg can add it automatically. But this requires **two settings both enabled**:

1. A table property: `write.spark.accept-any-schema = 'true'`
2. A writer option on every write: `.option("mergeSchema", "true")`

**Do NOT enable this in production for incremental pipelines.** Here's why: auto-evolution is convenient for ad-hoc tables, but once it's on, every accidental column change — a typo in a SELECT clause, a debug column someone forgot to remove, any stray test data — gets baked into the production schema permanently. Cleaning it up later requires an `ALTER TABLE ... DROP COLUMN` that needs coordination with downstream consumers. The manual `ALTER TABLE ... ADD COLUMN` path keeps every schema change deliberate and auditable.

Use auto-evolution only in development or for one-off analysis tables where you expect schema to change frequently.

### Full-Refresh Pipelines: Different Rule

If you're using `createOrReplace()` instead of `append()`, the rule flips. **Do NOT run `ALTER TABLE`** — `createOrReplace()` drops and rebuilds the entire table from your DataFrame's schema on every run. Any column you manually add with `ALTER TABLE` will disappear on the very next job run. Instead, update your Spark job's SELECT to include the new column, and the next run will recreate the table with it.

### Downtime? None Required

`ALTER TABLE ADD COLUMN` is metadata-only in Iceberg — no downtime. You can run it at any time while readers and writers are active. Add the column, deploy the job code update, and re-run. Old rows transparently return NULL; new rows have real values.

### Before the Next Change: Add a Preflight Check

Add a schema-diff check at the start of your job that compares Postgres's column list (via `information_schema.columns`) to your Iceberg table's schema. If they differ, alert the operator so they can run the `ALTER TABLE ADD COLUMN` before re-running. This makes schema mismatches visible immediately instead of at 2 AM when the sync fails.

---

**Path forward:** Run `ALTER TABLE iceberg.analytics.YOUR_TABLE ADD COLUMN new_column_name TYPE;` right now. No downtime. Then deploy your updated Spark job. New rows will have real values; old rows return NULL for the new column transparently.
