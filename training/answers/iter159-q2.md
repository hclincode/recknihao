# Iter 159 Q2 — Iceberg Schema Evolution: Adding Columns Safely

## Answer

## What Can Go Wrong When Adding a Column to an Iceberg Table

Good news: **adding a column to an Iceberg table is one of the safest schema changes you can make**. The `ALTER TABLE ADD COLUMN` operation is **metadata-only** — it doesn't touch any Parquet files, doesn't require rewrites, and completes in milliseconds. Concurrent Spark jobs and Trino queries don't break.

Here's what actually happens:

### Column Addition is Metadata-Only

When you run `ALTER TABLE user_events ADD COLUMN session_platform VARCHAR`, Iceberg:
1. Assigns a new column ID to `session_platform`
2. Updates the table's schema metadata in MinIO (the `metadata.json` file)
3. **Does NOT rewrite any Parquet data files**

This is fundamentally different from relational databases. In Postgres, adding a column to a large table can trigger a full table rewrite. In Iceberg, the files stay exactly as they are — the schema change is purely metadata.

### Old Parquet Files Return NULL Automatically

When someone queries your `user_events` table after the column addition:
- **Old Parquet files** (written before `session_platform` existed) — return `NULL` for `session_platform` on every row
- **New Parquet files** (written after the column addition) — return the actual `session_platform` value

There's no error. Iceberg's column-name-based schema matching simply returns NULL for columns that don't exist in older files.

```sql
-- This query works fine immediately after ALTER TABLE ADD COLUMN
SELECT event_id, user_id, session_platform
FROM user_events
WHERE occurred_at >= CURRENT_DATE - INTERVAL '30' DAY;

-- Results:
-- - Rows from old files show session_platform = NULL
-- - Rows from new files show the actual session_platform value
```

### Concurrent Readers and Writers Are Safe

**Readers (Trino queries)**: A Trino query that's already running when you add the column is unaffected. Trino snapshots the table's schema during planning; adding a column doesn't interrupt existing queries. New queries starting after the column addition see the new schema immediately.

**Writers (Spark jobs)**: Concurrent Spark ingestion jobs that were writing to the same table before the column addition will either:
- Write without the new column (if they don't know about it yet) — Iceberg handles the schema mismatch gracefully, and those rows return NULL for the new column
- Write with the new column (if they're updated to include it) — new rows have the value

Both writers can be active simultaneously. Iceberg's ACID semantics ensure consistency; writers don't conflict at the schema level.

### The Silent Failure: Column Promotion

The **only real gotcha** is when you promote a value from a JSON/MAP blob to a top-level column:

```sql
-- Before: session_platform was buried in a properties JSON blob
SELECT element_at(properties, 'session_platform') AS platform
FROM user_events;

-- You add a top-level column
ALTER TABLE user_events ADD COLUMN session_platform VARCHAR;

-- Now you repoint queries to use the new column
SELECT session_platform FROM user_events WHERE occurred_at >= ...;

-- SILENT FAILURE: old rows return NULL — historical data vanishes from dashboards
```

All historical rows return NULL for the newly-added `session_platform` because those Parquet files were written before the column existed. If your dashboard switches to querying the new column without a backfill, you'll lose all historical visibility without an error message.

**Mitigation**: If you're promoting an existing value from JSON into a top-level column:
1. Run `ADD COLUMN` (metadata-only, safe)
2. Run a one-time **backfill** Spark job that reads old rows, extracts the value from the JSON, and writes it back via `MERGE INTO`
3. Verify with `SELECT COUNT(*) WHERE session_platform IS NULL` on a partition you know had values
4. Only then switch dashboards to the new column

### Type Changes and Drops Are Different

This answer covers **column additions only**. Type changes (e.g., `VARCHAR` → `BIGINT`) are NOT allowed in-place in Iceberg — you must add a new column, backfill, then drop the old one. Column drops may require file rewrites in some cases. But plain `ADD COLUMN` with any type is always safe.

---

**Bottom line for your situation**: your `ALTER TABLE user_events ADD COLUMN session_platform VARCHAR` was fine. Any Spark jobs or Trino queries running at the time weren't broken. Old Parquet files automatically return NULL for that column. You only need a backfill if you want those historical rows to have non-NULL values.
