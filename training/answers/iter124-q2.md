# Iter124 Q2 — Answer

**Question**: A developer on my team added a column to our Postgres `events` table two weeks ago — just a new `referrer_source` column. Our Spark job that copies data from Postgres into Iceberg is still running fine with no errors, but when I query the Iceberg table the column is just all NULLs, even for new rows that came in after the column was added. What's happening and how do I fix it so new rows actually have the real values?

---

## Diagnosis: Your Spark Job is Silently Dropping the New Column

This is a **schema mismatch bug** in how Spark JDBC ingestion handles schema evolution with Iceberg 1.5.2. Your Spark job is succeeding (no errors, no warnings) but the new `referrer_source` column never reaches the Iceberg table. Here's exactly what's happening and how to fix it.

### Root cause

When your Spark job reads from Postgres with `SELECT * FROM events`, Spark's JDBC reader automatically detects the new `referrer_source` column and includes it in the DataFrame. But your Iceberg table **does not have this column yet** — it was created before the column was added to Postgres.

**Iceberg 1.5.2 is defensive by default** — it does not auto-add columns from incoming DataFrames. This is intentional safety behavior to prevent stray columns from silently drifting the schema. The result: the column is dropped before it reaches Iceberg, no error is raised, row counts grow, but `referrer_source` stays NULL.

The exact behavior depends on how your job writes:

| Write method | What happens when source has extra columns |
|---|---|
| `writeTo(...).append()` without schema merge | Job may fail with `AnalysisException` OR silently drop the column |
| `MERGE INTO` with `UPDATE SET *` / `INSERT *` | Column is silently dropped — Iceberg drops extra source columns not in the target schema |
| `MERGE INTO` with explicit column list | Column is silently dropped — not listed, so not written |

### How to diagnose which case you're in

Run this in Trino or Spark SQL:

```sql
DESCRIBE iceberg.analytics.events;
```

- **`referrer_source` column is absent** — The Iceberg table never acquired the column. Your Spark job wrote to a table that didn't have the column, so it was dropped.
- **`referrer_source` column is present but all NULL** — The column exists (maybe added manually earlier), but the Spark job isn't populating it. Likely an explicit column list in the MERGE or SELECT that omits the new field.

### The fix (in order)

**Step 1: Add the column to the Iceberg table schema explicitly.**

This is metadata-only — completes in milliseconds, no data rewrite:

```sql
ALTER TABLE iceberg.analytics.events
ADD COLUMNS (referrer_source VARCHAR);
```

Run this in Spark SQL or Trino. **This is always required** — Iceberg will not auto-add it from the DataFrame.

**Step 2: Fix your Spark job's source query to include the new column.**

If your Spark job has an explicit column list in its source query:

```python
# BEFORE — explicit list, misses referrer_source
df = spark.read.jdbc(
    url=PG_URL,
    table="(SELECT id, user_id, event_name, created_at FROM events) t",
    properties=PG_PROPS,
)
```

Update it:

```python
# AFTER — add the new column
df = spark.read.jdbc(
    url=PG_URL,
    table="(SELECT id, user_id, event_name, referrer_source, created_at FROM events) t",
    properties=PG_PROPS,
)
```

Or switch to `SELECT *` — simpler, but add the preflight check below to catch future drift early.

**Step 3: Verify your MERGE statement uses `*` wildcards, not explicit column lists.**

If your MERGE looks like this — **wrong**:

```sql
WHEN MATCHED THEN UPDATE SET
  t.event_name = s.event_name,
  t.created_at = s.created_at
  -- referrer_source not listed, so it never writes
WHEN NOT MATCHED THEN INSERT (id, user_id, event_name, created_at)
  VALUES (s.id, s.user_id, s.event_name, s.created_at)
```

Change it to wildcards — **correct**:

```sql
WHEN MATCHED AND s.op IN ('u') THEN UPDATE SET *
WHEN NOT MATCHED AND s.op IN ('c', 'r') THEN INSERT *
```

With `UPDATE SET *` and `INSERT *`, new columns in the source DataFrame automatically flow into the target table (as long as the Iceberg table schema has them, which Step 1 handles).

**Step 4: Re-run your Spark job.**

After the ALTER and the code changes, new rows should populate `referrer_source` with actual values.

### Backfill old rows (if you need them)

The `ALTER TABLE ... ADD COLUMNS` is metadata-only — it does not populate historical rows. All existing files return NULL for the new column because the column wasn't in those Parquet files when they were written. This is Iceberg's normal schema evolution behavior.

If you need historical `referrer_source` values, run a one-off backfill. Read from Postgres (which has the data), write to the existing Iceberg table:

```python
from datetime import date, timedelta

# Re-ingest rows from after the column was added (2 weeks ago)
cutoff = (date.today() - timedelta(days=14)).isoformat()

df = spark.read.jdbc(
    url=PG_URL,
    table=f"(SELECT * FROM events WHERE created_at >= '{cutoff}') t",
    properties=PG_PROPS,
)

# Use overwritePartitions to replace — idempotent, partition-scoped
df.writeTo("iceberg.analytics.events").overwritePartitions()
```

`overwritePartitions()` is safe — it only rewrites partitions that appear in the new data, leaving older partitions untouched. Run it once; if it fails partway through, it's safe to re-run.

### Prevention: add a preflight schema-check

Don't wait for the next schema-drift incident. Add this check at the start of every incremental Spark job:

```python
def preflight_schema_check(spark, pg_table, iceberg_table):
    pg_cols = spark.read.jdbc(
        url=PG_URL,
        table=f"(SELECT column_name FROM information_schema.columns WHERE table_name='{pg_table}') t",
        properties=PG_PROPS,
    ).collect()
    pg_col_names = {row.column_name for row in pg_cols}

    iceberg_cols = spark.sql(f"DESCRIBE TABLE {iceberg_table}").collect()
    iceberg_col_names = {
        row.col_name for row in iceberg_cols
        if row.col_name and not row.col_name.startswith("#")
    }

    new_in_postgres = pg_col_names - iceberg_col_names
    if new_in_postgres:
        raise Exception(
            f"Schema drift detected: columns in Postgres but not Iceberg: {new_in_postgres}. "
            f"Run: ALTER TABLE {iceberg_table} ADD COLUMNS (...) before re-running."
        )

# Call at job start:
preflight_schema_check(spark, "events", "iceberg.analytics.events")
```

This will raise an immediate error when Postgres changes, instead of silently writing NULLs for two weeks.

### Summary

| Step | What it does |
|---|---|
| `ALTER TABLE iceberg.analytics.events ADD COLUMNS (referrer_source VARCHAR)` | Adds column to Iceberg schema (metadata-only, instant) |
| Update Spark source query / MERGE to include `referrer_source` | Ensures new rows actually have the value |
| `overwritePartitions()` backfill from Postgres | Populates historical rows (run once) |
| Preflight schema check in Spark job | Prevents this from happening silently again |

**The core lesson:** Iceberg doesn't auto-evolve its schema from incoming DataFrames — you must explicitly `ALTER TABLE ... ADD COLUMNS` whenever a source schema changes. After that, all future writes and the `MERGE INTO ... SET *` pattern will pick up the new column automatically.
