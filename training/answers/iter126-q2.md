# Iter126 Q2 — Answer

**Question**: We need to rename a column in one of our main Iceberg tables — it's currently called `usr_id` and we want it to be `user_id` for consistency. The table has like 400 million rows. In Postgres I'd just do `ALTER TABLE ... RENAME COLUMN` and it's instant. Is it the same deal in Iceberg? Also separately, we realized one of our columns that stores amounts is typed as a string because of how it came out of Debezium, and we want to change it to a decimal. Are either of those safe to do without breaking existing Trino queries or messing up the data files?

---

## Column Rename: `usr_id` → `user_id`

**Completely safe, instant, no data rewrite.**

In Iceberg, column renames are **metadata-only operations**. Iceberg tracks columns by an internal **column ID** (assigned once when the column is created), not by name. When you rename a column, Iceberg updates the name mapping but the column ID stays the same. All existing Parquet files continue referencing the column by its original ID — nothing changes on disk.

```sql
ALTER TABLE iceberg.analytics.your_table RENAME COLUMN usr_id TO user_id;
```

This runs in milliseconds. Your 400 million rows don't move. Existing Trino queries keep working — Trino applies schema ID mapping at read time and surfaces the new name.

**What to watch for:** Any application code or dashboard query hardcoding `usr_id` will need updating after the rename. The change is instant on the Iceberg side, but downstream consumers still need to use the new name.

---

## Column Type Change: `VARCHAR` → `DECIMAL`

**Not directly allowed — requires a multi-step migration.**

Iceberg's spec defines exactly three safe type "promotions" (widening changes that require no data rewrite):

| Safe promotion | Example |
|---|---|
| `int` → `bigint` | `INT` → `BIGINT` |
| `float` → `double` | `FLOAT` → `DOUBLE` |
| `decimal(P, S)` → `decimal(P2, S)` where P2 > P | Precision widening, fixed scale |

Converting `VARCHAR` to `DECIMAL` is not on this list. Iceberg refuses because it would require validating every stored string value — a 400M-row full scan and rewrite. Instead, use the safe migration pattern:

### Four-step migration

```sql
-- Step 1: Add the new decimal column (metadata-only, instant)
ALTER TABLE iceberg.analytics.your_table
ADD COLUMN amount_decimal DECIMAL(19, 2);

-- Step 2: Validate — confirm there are no unconvertible values before backfill
SELECT COUNT(*)
FROM iceberg.analytics.your_table
WHERE amount_string IS NOT NULL
  AND TRY_CAST(amount_string AS DECIMAL(19, 2)) IS NULL;
-- If this returns > 0, you have junk data that will fail the CAST — clean it first.

-- Step 3: Backfill (reads and writes only affected partitions)
UPDATE iceberg.analytics.your_table
SET amount_decimal = CAST(amount_string AS DECIMAL(19, 2))
WHERE amount_string IS NOT NULL;

-- Step 4: Drop the old column after you've verified all queries use the new one
ALTER TABLE iceberg.analytics.your_table DROP COLUMN amount_string;
```

**Practical notes:**

- **Precision**: `DECIMAL(19, 2)` supports up to ~170 trillion with 2 decimal places. Adjust for your use case. Iceberg requires explicit precision — no unbounded `NUMERIC` like Postgres.
- **Backfill time**: The UPDATE in Step 3 rewrites data files for all affected partitions. For 400M rows, do this incrementally per partition (add a `WHERE ingested_at BETWEEN ...` clause). Don't scan the whole table in one shot.
- **Run Steps 1–3 while live**: Adding the new column and backfilling doesn't block reads on the old column. Only drop the old column (Step 4) after you've updated dashboards, queries, and the Spark ingestion job.
- **Debezium impact**: If Debezium feeds this table from Postgres, also update your Spark consumer to cast the value at ingest time: `col("amount_string").cast(DecimalType(19, 2))`. Or change the source Postgres column to `NUMERIC` and let Debezium emit the typed value.

### Why Iceberg behaves like Postgres here

In Postgres, `ALTER TABLE ... RENAME COLUMN` is instant for the same reason — Postgres also tracks columns by internal OID, not name. But `ALTER COLUMN ... TYPE` with a conversion Postgres can't do implicitly triggers a full table rewrite. Iceberg refuses the rewrite entirely and makes you do the migration explicitly — because rewriting 400M rows inside a DDL statement with no progress visibility would be unreliable.

---

## Summary

| Operation | Safe? | Duration | Notes |
|---|---|---|---|
| Rename `usr_id` → `user_id` | **Yes** | Milliseconds | Metadata-only; update downstream consumers |
| Change `VARCHAR` → `DECIMAL` | **Yes, multi-step** | Minutes (backfill) | Validate first; do incrementally by partition |

Do the rename immediately — no concerns. For the type change, plan a maintenance window, run the validation query first, then execute the four steps. Keep both columns live in parallel until all consumers have migrated.
