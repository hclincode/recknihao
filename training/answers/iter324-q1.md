# Answer to Q1: Trino 467 vs Spark for Iceberg Table Maintenance (Iter 324)

## The Version Mismatch

That syntax with `retain_last` and `clean_expired_metadata` was added in **Trino 479** (December 2025). On Trino 467, those parameters don't exist — which is exactly the error you saw.

## What Trino 467 Can Do

```sql
-- Expire snapshots older than 30 days (the only parameter available on Trino 467)
ALTER TABLE iceberg.analytics.events
EXECUTE expire_snapshots(retention_threshold => '30d');

-- Compact small files
ALTER TABLE iceberg.analytics.events
EXECUTE optimize(file_size_threshold => '128MB');

-- Remove orphan files (no dry_run on Trino 467 — see safety note below)
ALTER TABLE iceberg.analytics.events
EXECUTE remove_orphan_files(retention_threshold => '7d');
```

**Important floor:** Trino 467 enforces a 7-day minimum on `retention_threshold` for both `expire_snapshots` and `remove_orphan_files`. Anything shorter (e.g., `'3d'`) is rejected with a clear error.

## What Requires Spark

**`retain_last` and `clean_expired_metadata`** — use Spark's CALL form:

```sql
-- Spark SQL: expire snapshots but keep at least 10 most recent
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.events',
  older_than  => current_timestamp - interval '30' day,
  retain_last => 10
);
```

Spark has no 7-day floor, so it's also the path for urgent GDPR purges shorter than 7 days.

**`rewrite_manifests`** — not available on Trino 467 (added in Trino 470):

```sql
-- Spark SQL only on Trino 467
CALL iceberg.system.rewrite_manifests(table => 'analytics.events');
```

This rewrites metadata files to speed up query planning. If your table has accumulated thousands of manifest files, this is worth running from Spark.

**`dry_run` for orphan cleanup** — Trino 467's `remove_orphan_files` has no `dry_run` parameter. If you want to preview files before deleting, use Spark first:

```sql
-- Spark SQL: preview only (no files deleted)
CALL iceberg.system.remove_orphan_files(
  table   => 'analytics.events',
  dry_run => true
);
```

Then run the actual deletion from Trino once you've reviewed the output.

## Quick Reference: What Runs Where on Trino 467

| Operation | Trino 467 | Spark |
|---|---|---|
| `expire_snapshots` (basic, retention_threshold only) | ✓ | ✓ |
| `expire_snapshots` with `retain_last` or `clean_expired_metadata` | ✗ (Trino 479+) | ✓ |
| `expire_snapshots` < 7-day retention | ✗ (floor enforced) | ✓ (no floor) |
| `optimize` (compaction) | ✓ | ✓ |
| `remove_orphan_files` | ✓ (no dry_run) | ✓ (with dry_run) |
| `rewrite_manifests` | ✗ (Trino 470+) | ✓ |

## Recommended Cleanup Sequence for Your Situation

```sql
-- Step 1: Compact first (creates fewer, larger files before expiry)
ALTER TABLE iceberg.analytics.events
EXECUTE optimize(file_size_threshold => '128MB');

-- Step 2: Expire old snapshots
ALTER TABLE iceberg.analytics.events
EXECUTE expire_snapshots(retention_threshold => '30d');

-- Step 3: Remove orphan files
ALTER TABLE iceberg.analytics.events
EXECUTE remove_orphan_files(retention_threshold => '7d');
```

Run step 3 from Spark with `dry_run => true` first if you want to preview what will be deleted. After the one-time cleanup, schedule these weekly.
