# Answer to Q2: Adding a Column to a Live Iceberg Table Without Rewriting Data (Iter 304)

**Short answer: Iceberg never rewrites existing Parquet files when you add a column.** The operation is metadata-only — it takes milliseconds regardless of table size, and the old files remain untouched on MinIO.

## How Iceberg Schema Evolution Works (Field-ID Mechanism)

Iceberg doesn't track columns by name. Instead, every column has a **permanent numeric field ID** assigned when the column is first created. When you add a new column via `ALTER TABLE ... ADD COLUMN`, Iceberg:

1. Assigns a new unique field ID to the column (e.g., field ID 42).
2. Updates only the table's **schema metadata file** (`metadata.json` stored in MinIO).
3. Makes **zero changes** to existing Parquet data files.

When Trino reads an old Parquet file written before the new column existed:
- The old file has data for field IDs 1–41 (the original columns).
- The table schema includes field ID 42 (the new column).
- Iceberg's reader matches columns to files **by field ID**, not by name.
- Field ID 42 is not present in the old file → Iceberg returns **NULL for every row**.

```sql
-- Add a column to live table. Instant — metadata-only.
ALTER TABLE iceberg.analytics.events
ADD COLUMN region VARCHAR;

-- Old rows now read as NULL for region.
SELECT event_id, region
FROM iceberg.analytics.events
WHERE occurred_at < TIMESTAMP '2026-05-20 00:00:00';
-- Result: every old row shows NULL for region
```

## Why Field-ID Matching Is Safer Than Name Matching

Compare to plain Parquet:
- **Plain Parquet (fragile)**: matches columns by name. Rename a column → old files stop matching, data silently vanishes.
- **Iceberg (safe)**: matches by field ID. A rename is just a metadata change — field ID stays the same, old files keep matching correctly.

## Operations That Are Metadata-Only vs Require File Rewrites

**Metadata-only (instant, any table size):**
- `ADD COLUMN` — assigns new field ID, updates schema only
- `DROP COLUMN` — retires field ID; queries skip the column, bytes remain in old files until compaction
- `RENAME COLUMN` — field ID stays the same, schema gets new name; old files still match
- `REORDER COLUMNS` — field IDs unchanged, just schema ordering
- Type promotion (e.g., `int → bigint`) — schema update only if within Iceberg-allowed promotions

**Require file rewrite (slow on large tables, done via compaction):**
- Backfilling a newly-added column with computed historical values — explicitly required to avoid silent data loss
- Type changes outside Iceberg's safe promotion list (e.g., `varchar → int`)
- `SET NOT NULL` on a column — requires verifying all existing rows satisfy the constraint

## How Trino Handles Mixed-Schema Files in a Single Query

When a query scans files from before and after the schema change:

1. Iceberg's connector identifies all files in the result set from the manifest index.
2. For each file, it maps the file's field IDs to the current table schema.
3. Field IDs missing from an old file → NULL column produced on the fly.
4. The result set seamlessly mixes old rows (NULL for new column) and new rows (real values) — no error, no rewrite.

```sql
-- Query spanning old and new files:
SELECT event_id, occurred_at, region
FROM iceberg.analytics.events
WHERE occurred_at BETWEEN TIMESTAMP '2026-05-15 00:00:00'
                      AND TIMESTAMP '2026-05-25 00:00:00';
```

Results:
- Rows from 2026-05-15 to 2026-05-20 (old files): `region = NULL`
- Rows from 2026-05-20 to 2026-05-25 (new files): `region = <actual value>`

## The Silent Data Loss Trap

Adding a column and immediately filtering on it will silently exclude all historical rows:

```sql
-- DANGEROUS — silently excludes all rows written before the column was added
SELECT COUNT(*)
FROM iceberg.analytics.events
WHERE region = 'us-east-1';
-- Returns only rows from new files; historical rows (region = NULL) are excluded
```

If your dashboard or report filters or groups by the new column before backfill is done, it appears to show zero historical data. No error — just missing rows.

## Production Workflow: Safe Column Add + Backfill

**Step 1: Add the column (instant)**
```sql
ALTER TABLE iceberg.analytics.events
ADD COLUMN region VARCHAR;
```

**Step 2: Verify old rows return NULL**
```sql
SELECT COUNT(*) AS null_count
FROM iceberg.analytics.events
WHERE region IS NULL
  AND occurred_at < TIMESTAMP '2026-05-20 00:00:00';
-- Expected: all pre-add rows
```

**Step 3: Backfill historical rows (Spark, partition-scoped)**
```sql
-- Spark SQL — targeted MERGE INTO for the backfill
MERGE INTO iceberg.analytics.events AS target
USING (
  SELECT event_id, element_at(properties, 'region') AS region
  FROM iceberg.analytics.events
  WHERE region IS NULL
    AND occurred_at < TIMESTAMP '2026-05-20 00:00:00'
) AS source
ON target.event_id = source.event_id
WHEN MATCHED THEN UPDATE SET region = source.region;
```

Run during off-peak hours. Scope to one partition at a time for large tables to avoid overwhelming the cluster.

**Step 4: Verify backfill is complete**
```sql
SELECT COUNT(*) AS remaining_nulls
FROM iceberg.analytics.events
WHERE region IS NULL
  AND occurred_at < TIMESTAMP '2026-05-20 00:00:00';
-- Should be ~0 when done
```

**Step 5: Only after verification, update dashboards to use the new column.**

## What Happens to Dropped Columns

When you drop a column, Iceberg retires its field ID in the schema — queries no longer return it. But the bytes remain physically in the Parquet files until you run compaction. This is intentional: the drop is instant (metadata-only), and Iceberg's reader simply ignores the orphaned field IDs when reading old files.

To physically reclaim the storage, run a Spark compaction after the drop:
```sql
-- Spark — rewrites files without the dropped column's bytes
CALL iceberg.system.rewrite_data_files('analytics.events');
```

## Your Specific Scenario

Adding a "region" column for a new tenant-configurable field:
1. `ALTER TABLE ... ADD COLUMN region VARCHAR` — instant, zero downtime, no file rewrites
2. New ingestion writes `region` values to new Parquet files immediately
3. Old Parquet files stay unchanged on MinIO; queries see NULL for `region` on old rows
4. Run backfill from `properties` JSON if needed for historical rows
5. Dashboard queries that filter `WHERE region = '...'` will silently miss pre-add rows until backfill is done — don't wire those queries up early

The operational cost is the backfill job and testing discipline, not the schema change itself.
