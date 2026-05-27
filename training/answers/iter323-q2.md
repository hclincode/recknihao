# Answer to Q2: First-Run Snapshot Expiry After 6 Months + clean_expired_metadata (Iter 323)

You're right to be careful — running snapshot expiry for the first time on accumulated history is a legitimate concern. The good news: it won't blow up, and it doesn't process all six months at once in a way that will lock up or crash.

## What expire_snapshots Does on First Run

When you call `expire_snapshots`, Iceberg:

1. **Scans the snapshot list** — metadata-only operation on the Hive Metastore entry. Fast, typically under a second even with thousands of snapshots.
2. **Marks snapshots as expired** — any snapshot older than your cutoff gets flagged. Metadata bookkeeping, not I/O intensive.
3. **Issues DELETE calls to MinIO** — for files no longer referenced by any live snapshot. This is where the real work is, but it's concurrent and batched, not serialized through six months one by one.

On six months of history, the metadata scan is still fast. The MinIO deletes can take a few minutes depending on file count, but it won't timeout or OOM.

## The 7-Day Floor is Your Safety Net

Trino 467 enforces `iceberg.expire-snapshots.min-retention` (default 7 days) as a hard minimum. You cannot expire snapshots younger than 7 days — Trino rejects with a clear error. This is actually a safety feature for your first run: even if you made a mistake in the threshold, you always retain at least a 7-day rollback window.

## Running the First Expiry Safely

```sql
-- Trino 467 — recommended first-run form
ALTER TABLE iceberg.analytics.events
EXECUTE expire_snapshots(
  retention_threshold   => '30d',
  retain_last           => 10,
  clean_expired_metadata => true
);
```

**What each parameter does:**
- `retention_threshold => '30d'`: expire snapshots older than 30 days (must be ≥ 7 days or Trino rejects it)
- `retain_last => 10`: keep at least the 10 most recent snapshots regardless of age — safety net
- `clean_expired_metadata => true`: **this is the one you asked about** — it also cleans up expired schema versions, partition specs, and sort orders that are no longer referenced by any live snapshot. Without it, `expire_snapshots` only removes snapshot pointers and data files; stale metadata objects accumulate. For a first run after 6 months, set this to `true`.

## What to Expect on First Run

- **Metadata scan**: ~1–5 seconds
- **MinIO deletes**: depends on file count — 100K files might take 1–10 minutes. Normal and expected.
- **No coordinator lock**: Trino continues serving other queries while expiry runs
- **No query interference**: reads and writes to the table continue normally; the procedure doesn't block them

## The safe ordering for first run

```sql
-- Step 1: Expire old snapshots (Trino 467)
ALTER TABLE iceberg.analytics.events
EXECUTE expire_snapshots(
  retention_threshold    => '30d',
  retain_last            => 10,
  clean_expired_metadata => true
);

-- Step 2: Remove orphan files (Trino 467 has no dry_run — test on a staging table first)
ALTER TABLE iceberg.analytics.events
EXECUTE remove_orphan_files(retention_threshold => '7d');
```

**Important Trino 467 detail**: `remove_orphan_files` via Trino has NO `dry_run` parameter. Only the Spark form supports preview mode:

```python
# Optional preview from Spark before committing to Trino
CALL iceberg.system.remove_orphan_files(
  table   => 'analytics.events',
  dry_run => true
);
```

## Will Six Months of Snapshots Slow Down the First Run?

**No.** The metadata scan is fast regardless of history depth. The file deletion is concurrent. Expect a few seconds to a few minutes total depending on MinIO performance and file count — not hours.

## After the First Run: Schedule Routine Maintenance

Once you've cleared the backlog, schedule weekly:

```sql
-- Weekly Trino maintenance job
ALTER TABLE iceberg.analytics.events
EXECUTE expire_snapshots(
  retention_threshold    => '30d',
  retain_last            => 10,
  clean_expired_metadata => true
);

ALTER TABLE iceberg.analytics.events
EXECUTE remove_orphan_files(retention_threshold => '7d');
```

The first run does the heavy lifting. Subsequent runs process only the incremental week's worth of new snapshots — much faster.
