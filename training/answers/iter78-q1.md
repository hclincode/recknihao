# Iter78 Q1 — Answer

**Question**: Someone manually added a column to Iceberg via `ALTER TABLE ADD COLUMN`. The Spark sync job still uses the old Postgres schema (DataFrame doesn't have the new column). What happens when the job runs? Does it crash, silently drop the column, or handle it automatically?

---

## Answer

Your situation is well-documented in the Iceberg + Spark integration. What happens depends on whether the column was added to Iceberg but NOT in the DataFrame (your scenario) — or vice versa.

### Your scenario: column added to Iceberg, DataFrame missing it

**The Spark job runs successfully and rows are written — but the new Iceberg column gets NULL for every new row.**

Here's why: when your DataFrame has *fewer* columns than the Iceberg table, Spark fills in NULL for the missing columns. The DataFrame doesn't mention the new column, so Iceberg treats it as unset. No crash, no error.

This is the **silent-omission case** — the job runs green, dashboards keep working, and no one notices for weeks that the new column is always NULL in newly written rows.

### The opposite scenario: column in DataFrame, not in Iceberg

**This is the fail-by-default case.** If the Iceberg table does NOT have the column yet, and your DataFrame does (e.g., because Postgres grew a new column and your job uses `SELECT *`), then `writeTo().append()` **fails with a schema mismatch error** — a `ValidationException` saying there are extra columns in the DataFrame that don't exist in Iceberg.

This defensive behavior is intentional: Iceberg refuses to silently extend the table schema from whatever the Spark job happens to send.

To get auto-evolution in this scenario, you'd need BOTH:
- Table property `write.spark.accept-any-schema=true`
- Writer option `.option("mergeSchema", "true")`

Without those, the standard path is `ALTER TABLE ADD COLUMNS` first, then re-run.

### How Spark and Iceberg schemas relate

They are **separate and must be kept in sync manually**:
- **Spark's DataFrame schema** = what the JDBC query returns (whatever columns your SELECT lists)
- **Iceberg's table schema** = what columns the table was defined with, plus anything added via `ALTER TABLE`

When you call `.append()`, Spark checks the two schemas:
- DataFrame has extra columns Iceberg doesn't know → **fails**
- DataFrame is missing columns Iceberg has → **silently NULLs them**

### Fix for your situation

Since Iceberg already has the new column (someone ran `ALTER TABLE ADD COLUMN`), your job is in the silent-NULL state. To actually populate the new column:

1. **Update your Spark job's JDBC query** to include the new column from Postgres:

```python
df = spark.read.jdbc(
    url=PG_URL,
    table="(SELECT id, tenant_id, ..., new_column, updated_at FROM events WHERE updated_at > '{last_ts}') t",
    properties=PG_PROPS,
)
df.writeTo("iceberg.analytics.your_table").append()
```

2. **Re-run the job.** New rows now get the real value. Old rows (written before this fix) continue returning NULL for the new column — Iceberg fills in NULL for existing Parquet files automatically. No backfill required unless you want non-NULL values for historical rows.

### Key mental model

| Situation | What happens |
|---|---|
| Column in Iceberg, missing from DataFrame | Job succeeds; new rows get NULL for that column |
| Column in DataFrame, missing from Iceberg | Job FAILS with schema mismatch (default behavior) |
| Column in both | Job succeeds normally |
| Neither (using explicit column list) | Column silently excluded; job succeeds but data lost |

**Prevention**: add a preflight schema check to your job's startup that diffs Postgres columns against the Iceberg table columns and fails loudly when they diverge — this turns a silent NULL problem into an explicit alert before it affects production data.
