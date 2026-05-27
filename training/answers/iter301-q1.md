# Answer to Q1: dbt Incremental Models on Iceberg — Watermarks, unique_key, and Strategies

## How dbt detects "new" rows: the watermark pattern

dbt incremental models use a **watermark filter** on a timestamp column (`updated_at`, `created_at`) to detect which rows are new or changed since the last run. dbt handles this via the `is_incremental()` Jinja macro in your SQL model:

```sql
{{ config(
  materialized='incremental',
  unique_key='order_id',
  incremental_strategy='merge'
) }}

SELECT order_id, customer_id, amount, status, updated_at
FROM {{ source('app', 'orders') }}
{% if is_incremental() %}
  WHERE updated_at > (SELECT MAX(updated_at) FROM {{ this }})
{% endif %}
```

On the first run, `is_incremental()` returns false and the full table is loaded. On subsequent runs, it returns true and the watermark filter limits the scan to rows updated since the last run's max timestamp.

**This is not automatic magic** — it requires the source table to have a timestamp column that your application keeps fresh on every INSERT and UPDATE. If `updated_at` can be backdated by migrations or backfills, incremental models will silently miss those rows. The fix is either a periodic full-refresh reconciliation, or using Postgres's `xmin` (transaction ID) as the watermark instead of a timestamp.

## The mutable-data problem and unique_key

If orders can be updated after insertion, **append-only will give you duplicates**. This is what `unique_key` solves.

On Iceberg, `unique_key` config translates to **SQL's `MERGE INTO`** under the hood — it's a database-level upsert, not dbt-level deduplication:

```sql
-- What dbt compiles to (simplified):
MERGE INTO iceberg.analytics.orders AS t
USING new_data AS s
ON t.order_id = s.order_id
WHEN MATCHED AND s.updated_at > t.updated_at THEN UPDATE SET *
WHEN NOT MATCHED THEN INSERT *
```

- Rows that already exist (matched by `order_id`) are updated if the source has a newer `updated_at`
- New rows (unmatched) are inserted
- No duplicates — each `order_id` appears once in the final table

## The three incremental strategies on Iceberg

| Strategy | What it does under the hood | When to use |
|---|---|---|
| **`append`** | Appends new rows without touching existing rows | Immutable tables (events, logs) where rows never change. **Never use for orders.** |
| **`merge`** (default on Iceberg) | `MERGE INTO` — updates matched rows by `unique_key`, inserts unmatched ones | Dimension tables and fact tables with mutable data (orders, subscriptions, user profiles) |
| **`insert_overwrite`** | Overwrites a partition completely — all rows in the matching partition are replaced | Full-day reloads when you want to replace "today's data" atomically. Requires a partitioned table. |

For your mutable orders table: use `incremental_strategy='merge'` with `unique_key='order_id'`.

## Copy-on-Write vs Merge-on-Read

When dbt runs a `MERGE INTO` on Iceberg, how rows are physically updated depends on the table's write mode:

**Copy-on-Write (CoW) — Iceberg 1.5.2 default:**
- Every matched row is rewritten to a new Parquet file. Old files are orphaned (cleaned up by `remove_orphan_files`).
- Write cost: higher. Read cost: lower (no delete files to merge at query time).
- Best for: infrequent upserts (daily dbt incremental batch on dimension tables).

**Merge-on-Read (MoR) — must be enabled explicitly:**
```sql
ALTER TABLE iceberg.analytics.orders SET TBLPROPERTIES (
  'write.delete.mode'  = 'merge-on-read',
  'write.update.mode'  = 'merge-on-read',
  'write.merge.mode'   = 'merge-on-read'
);
```
- Updated rows are marked with small delete files; original data files stay intact.
- Write cost: lower. Read cost: higher (every scan merges data + delete files).
- Best for: high-frequency updates (many micro-batches per hour).

For daily dbt incremental models, **stick with Copy-on-Write (the default)**. The write cost is paid in the batch window, and readers get clean scans. Only switch to MoR if you run many incremental batches per hour.

## on_schema_change behavior

```sql
{{ config(
  on_schema_change='append_new_columns'  -- or 'fail', 'ignore', 'sync_all_columns'
) }}
```

On Iceberg:
- **`fail`** (default) — the dbt run errors if the source schema is wider than the target.
- **`sync_all_columns`** — dbt auto-evolves the Iceberg table with `ALTER TABLE ... ADD COLUMN`. Works because Iceberg's column IDs are immutable; adding columns is backward-compatible with existing Parquet files.
- **`append_new_columns`** — similar, but only adds columns, never removes.

**Gotcha on column removal:** When a column is dropped from the source, dbt's MERGE INTO silently omits it from the INSERT/UPDATE. The column stays in Iceberg with NULL for future rows — it's never deleted from the schema. Iceberg's versioning design makes column removal a deliberate DDL operation, not automatic.

## Iceberg-specific considerations

**Partition pruning on the incremental filter:** If your table is partitioned by `day(updated_at)` and your watermark filters on `updated_at`, Iceberg automatically prunes partitions — only the affected partition files are scanned. Very efficient; dbt doesn't need to do anything extra.

**Snapshot isolation:** Every dbt run creates a new Iceberg snapshot. If a run produces bad data, you can roll back: `CALL iceberg.system.rollback_to_snapshot('iceberg.analytics.orders', <snapshot_id>)`. No data loss. But you must run periodic `expire_snapshots` + `remove_orphan_files` to reclaim MinIO storage.

**Small-file accumulation:** Frequent incremental runs (especially with `merge`) create many small files as CoW rewrites matching rows into new files. Schedule nightly compaction:
```sql
ALTER TABLE iceberg.analytics.orders
EXECUTE optimize(file_size_threshold => '256MB');
```
Without compaction, query performance degrades as the planner has to open hundreds of small files.

**Late-arriving data:** If orders can arrive with timestamps from 3+ days ago (mobile app, offline retry), your partition filter might miss them. Widen the incremental window:
```sql
{% if is_incremental() %}
  WHERE ingested_at >= TIMESTAMP '{{ run_started_at - macros.timedelta(days=4) }}'
    AND updated_at > (SELECT MAX(updated_at) FROM {{ this }})
{% endif %}
```

## Summary for mutable orders

```sql
{{ config(
  materialized='incremental',
  unique_key='order_id',
  incremental_strategy='merge',
  on_schema_change='append_new_columns'
) }}

SELECT order_id, customer_id, amount, status, updated_at
FROM {{ source('app', 'orders') }}
{% if is_incremental() %}
  WHERE updated_at > (SELECT MAX(updated_at) FROM {{ this }})
{% endif %}
```

- `unique_key='order_id'` → MERGE INTO deduplicates; each order_id appears once.
- `incremental_strategy='merge'` → updated orders get updated, not duplicated.
- `on_schema_change='append_new_columns'` → new Postgres columns auto-propagate to Iceberg.
- CoW default → clean reads, daily batch write cost is fine.
- Schedule nightly `optimize` to compact small files from daily merges.
