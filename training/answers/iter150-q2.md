# Iter 150 Q2 — Iceberg Safe Backfill with Staging and View Swap

## Answer

Yes — Iceberg has a safe staging pattern for exactly this scenario. You have two practical options on Iceberg 1.5.2 + Trino 467.

### Option 1: Staging table + atomic view swap (recommended for large backfills)

This is the standard pattern for validating a full data reload before any reader sees it.

**Step 1: Load into a separate staging table**

```sql
INSERT INTO iceberg.analytics.events_staging
SELECT * FROM your_old_system.events
WHERE event_date >= DATE '2024-11-01' AND event_date < DATE '2026-05-26';
```

The production `events` table is untouched. All live dashboard queries keep running against the current data.

**Step 2: Validate the staging table**

```sql
-- Row count and date range sanity check
SELECT COUNT(*), MIN(event_date), MAX(event_date)
FROM iceberg.analytics.events_staging;

-- Tenant ID sanity check
SELECT COUNT(DISTINCT tenant_id) FROM iceberg.analytics.events_staging;

-- Duplicate check on your natural key
SELECT event_id, COUNT(*) AS cnt
FROM iceberg.analytics.events_staging
GROUP BY event_id
HAVING cnt > 1;
```

Run these checks, fix any issues in the staging table (DELETE duplicates, correct bad tenant IDs) before proceeding.

**Step 3: Atomically swap the view**

```sql
-- One atomic metadata commit — readers see old or new, never a partial state
CREATE OR REPLACE VIEW iceberg.analytics.events_live AS
SELECT * FROM iceberg.analytics.events_staging;
```

**Step 4: Keep the old table as a rollback option**

```sql
ALTER TABLE iceberg.analytics.events RENAME TO events_backup_2026_05;
```

If you discover problems after the swap (wrong tenant IDs, duplicate counts off by 5%), you instantly revert:

```sql
-- Revert
CREATE OR REPLACE VIEW iceberg.analytics.events_live AS
SELECT * FROM iceberg.analytics.events_backup_2026_05;
```

**Why this is safe:**

- **Snapshot isolation**: Iceberg guarantees that queries running against the old table see the snapshot that was current when they started, even while you're writing the staging table. Live dashboard queries are never interrupted.
- **View swap is atomic**: Creating or replacing a view is a single metadata commit. Consumers see either the old definition or the new one — never a partial state.
- **Easy rollback**: The old table persists until you explicitly drop it. Reverting is one SQL statement.

**Critical prerequisite — audit your consumers:**

The view-swap pattern only works if every consumer queries the **view name** (`events_live`), not the raw base table name (`events`). Before the cutover:

- Grep dbt models, Airflow DAGs, dashboard saved queries, and application code for the base table name
- Every hit must be repointed to the view before cutover
- Consumers still pointing at the base table will silently keep reading old data — there is no error, just wrong results

### Option 2: Partition-scoped overwrite (if table is partitioned by day)

If your production `events` table is partitioned by day, you can validate and commit one day at a time without a separate staging table:

```sql
-- Load day by day — each partition is overwritten atomically
INSERT OVERWRITE iceberg.analytics.events
  PARTITION (event_date = '2024-11-01')
SELECT * FROM your_old_system.events
WHERE event_date = '2024-11-01';

-- Validate before moving to next day
SELECT COUNT(*) FROM iceberg.analytics.events WHERE event_date = DATE '2024-11-01';
```

Iceberg's snapshot isolation means live queries see either the old partition or the fully-written new one — never a partial load. The downside: 18 months is ~550 days, each requiring a loop iteration, and each commit adds a snapshot. Run compaction and `expire_snapshots` afterward.

### What NOT to do

- **Do NOT `INSERT INTO` the live table directly** if the data has not been validated. Any bad rows (wrong tenant IDs, duplicates) are immediately visible to live dashboard queries.
- **Do NOT rely on compaction to fix data quality issues**. Compaction optimizes file sizes — it does not remove wrong tenant IDs or deduplicate rows.

### After the backfill commits — run maintenance

A large backfill creates many small files and a large snapshot history. Run these in order (Spark form):

```sql
-- 1. Compact small files
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.events',
  options => map('target-file-size-bytes', '268435456', 'min-input-files', '5')
);

-- 2. Expire old snapshots
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.events',
  older_than  => current_timestamp - interval '7' day,
  retain_last => 10
);

-- 3. Remove orphan files
CALL iceberg.system.remove_orphan_files(
  table      => 'analytics.events',
  older_than => current_timestamp - interval '3' day
);
```

### Summary

| Approach | Use when | Risk |
|---|---|---|
| Staging table + view swap | Large backfill, need full validation before exposure | Requires all consumers to use the view name (not base table) |
| Partition overwrite | Table already partitioned by day; can validate day-by-day | Slower (550 loop iterations); many snapshots to expire |
| Write to a separate staging table then INSERT...SELECT | Only if no view infrastructure exists | Briefly exposes data in production before validation window |

The staging table + view swap is the cleanest approach for 18 months of data. It gives you unlimited validation time before any live reader sees anything.
