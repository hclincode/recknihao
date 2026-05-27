# Answer to Q2: Iceberg $manifests diagnostics — correct column names (Iter 328)

## The exact correct column names

- **Manifest file size**: `length` (BIGINT) — NOT `manifest_length`, NOT `file_size`
- **Data files per manifest**: `added_data_files_count` (INTEGER) — NOT `data_files_count`, NOT `added_files_count`

**`manifest_length` does not exist.** Using it returns "Column not found: manifest_length" at runtime. The column is simply named `length`.

## Complete working Trino 467 diagnostic query

```sql
SELECT
  COUNT(*) AS manifest_count,
  SUM(length) / 1024 / 1024 AS total_manifest_mb,
  ROUND(AVG(added_data_files_count)) AS avg_files_per_manifest,
  MAX(added_data_files_count) AS max_files_per_manifest
FROM iceberg.analytics."events$manifests";
```

What this tells you:
- `manifest_count` — how many manifests exist (> 200 = query planning is likely slow)
- `total_manifest_mb` — bytes of manifest metadata Trino reads during every query plan
- `avg_files_per_manifest` — if < 5, you're in a streaming/micro-batch pattern and manifests accumulate fast
- `max_files_per_manifest` — largest single manifest (a few hundred is typical for batch jobs)

## The correct Trino quoted syntax

The `$` character requires double quotes in Trino:

```sql
-- CORRECT
SELECT COUNT(*) FROM iceberg.analytics."events$manifests";

-- WRONG — fails with "table not found"
SELECT COUNT(*) FROM iceberg.analytics.events$manifests;
```

Always use: `"catalog"."schema"."table$manifests"` (or `catalog.schema."table$manifests"` — the quotes only need to wrap the `$` token).

## All columns in `$manifests`

| Column | Type | What it tells you |
|---|---|---|
| `content` | INTEGER | 0 = data files, 1 = delete files |
| `path` | VARCHAR | MinIO/S3 path to the manifest file |
| `length` | BIGINT | **Manifest file size in bytes** (this is the one you want) |
| `partition_spec_id` | INTEGER | Which partition spec version this manifest uses |
| `added_snapshot_id` | BIGINT | Which snapshot created this manifest |
| `added_data_files_count` | INTEGER | **Data files added in this manifest** |
| `added_rows_count` | BIGINT | Total rows added |
| `existing_data_files_count` | INTEGER | Data files inherited from prior snapshots |
| `existing_rows_count` | BIGINT | Existing rows inherited |
| `deleted_data_files_count` | INTEGER | Data files removed (compaction or deletes) |
| `deleted_rows_count` | BIGINT | Rows deleted |
| `partition_summaries` | ARRAY(ROW) | Per-partition min/max statistics for column pruning |

## Example: before/after rewrite_manifests

```sql
-- Before: capture baseline
SELECT COUNT(*) AS manifest_count, SUM(length) / 1024 / 1024 AS total_mb
FROM iceberg.analytics."events$manifests";

-- Run the fix from Spark (optimize_manifests requires Trino 470+, not available on Trino 467):
-- CALL iceberg.system.rewrite_manifests(table => 'analytics.events');

-- After: verify 80-95% reduction
SELECT COUNT(*) AS manifest_count, SUM(length) / 1024 / 1024 AS total_mb
FROM iceberg.analytics."events$manifests";
```

The `length` column (not `manifest_length`) is the total bytes of each manifest file. Summing it gives you the total metadata Trino must read during every query plan.
