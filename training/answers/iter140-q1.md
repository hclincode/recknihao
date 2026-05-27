# Iter140 Q1 — Answer

**Question**: "We run a lot of UPDATE and DELETE operations on our Iceberg tables — things like correcting bad event data after a CDC pipeline glitch, or removing a customer's records for GDPR compliance. We noticed that after a big DELETE run, our query times went back up even though the table supposedly has fewer rows. When I look at the file count in the metadata, it looks like it went UP rather than down. What actually happens on disk when you delete rows from an Iceberg table, and why would a delete operation leave you with more files than you started with?"

---

## Two Delete Modes: Copy-on-Write and Merge-on-Read

Iceberg supports two fundamentally different approaches to deletion. They produce opposite effects on disk.

### Copy-on-Write (CoW) — the Iceberg 1.5.2 Default

When you `DELETE FROM ... WHERE ...` in CoW mode:
1. Iceberg reads every Parquet data file containing at least one matching row.
2. Filters out the deleted rows in memory.
3. Writes **brand new** Parquet files containing only the surviving rows.
4. The original files are immediately dereferenced from the current snapshot.

**Effect on file count:** typically stays the same or decreases. You replace N old files with N new (slightly smaller) files. MinIO storage temporarily grows because both old and new files coexist until `expire_snapshots` cleans up.

### Merge-on-Read (MoR) — must be explicitly enabled

When you `DELETE FROM ... WHERE ...` in MoR mode:
1. Iceberg writes a small **delete file** — metadata listing which rows in which data files to ignore at query time.
2. The original Parquet data files are **completely untouched**.
3. The delete file is added to the current snapshot alongside the existing data files.

**Effect on file count:** **increases visibly**, because a new delete file exists for every batch of deleted rows. Queries must merge delete files with data files at read time — this is why queries slowed down even though you have fewer logical rows.

---

## Which Mode Are You Using?

**Iceberg 1.5.2 defaults to CoW for all three operations: DELETE, UPDATE, and MERGE.**

If your file count went up after a DELETE, you are likely using MoR. Check:

```sql
-- Trino: check table properties
SELECT * FROM iceberg.your_schema."your_table$properties"
WHERE key LIKE 'write.%mode';
```

Look for `write.delete.mode`, `write.update.mode`, `write.merge.mode`. If any are set to `merge-on-read`, that explains the file increase.

Diagnose delete file accumulation directly:

```sql
-- Trino: count data files vs delete files
SELECT
    COUNT(*) FILTER (WHERE content = 0) AS data_files,
    COUNT(*) FILTER (WHERE content = 1) AS position_delete_files,
    COUNT(*) FILTER (WHERE content = 2) AS equality_delete_files
FROM iceberg.your_schema."your_table$files";
```

If `position_delete_files` or `equality_delete_files` is high, delete files are accumulating.

---

## Why Query Times Go Up Even in CoW Mode

If you're using CoW and file count didn't dramatically increase but queries are slower, the issue is **small file fragmentation**:

- Before: 50 compacted files at 256 MB each.
- You DELETE 10% of rows; CoW rewrites 48 of those files.
- New files are ~230 MB each (10% smaller due to deleted rows).
- Trino still opens 48 files with more overhead than before (if the rewrite split some files further).

The fix: run compaction immediately after a large DELETE.

---

## Fixes

### Fix 1: Compact after large DELETEs (CoW case)

```sql
-- Trino 467 (ad-hoc)
ALTER TABLE iceberg.analytics.events EXECUTE optimize(file_size_threshold => '128MB');

-- OR Spark (more control)
CALL iceberg.system.rewrite_data_files(
    table   => 'analytics.events',
    options => map('target-file-size-bytes', '268435456', 'min-input-files', '3')
);
```

### Fix 2: Apply pending MoR deletes (MoR case)

If you're using MoR and delete files have accumulated, consolidate them:

```sql
-- Spark SQL: apply all pending deletes and rewrite clean data files
CALL iceberg.system.rewrite_data_files(
    table   => 'analytics.events',
    options => map(
        'delete-file-threshold', '1',           -- rewrite any file with 1+ delete file
        'target-file-size-bytes', '268435456'
    )
);
```

### Fix 3: Switch from MoR to CoW (for better query performance)

```sql
-- Trino or Spark (affects NEW operations only)
ALTER TABLE iceberg.analytics.events SET TBLPROPERTIES (
    'write.delete.mode' = 'copy-on-write',
    'write.update.mode' = 'copy-on-write',
    'write.merge.mode'  = 'copy-on-write'
);
```

---

## GDPR Compliance: 3-Step Physical Deletion Sequence

`DELETE FROM` alone does not physically remove bytes from MinIO — old snapshots still reference the old data files. Full physical deletion requires three steps:

**Step 1: DELETE the rows**
```sql
DELETE FROM iceberg.analytics.events WHERE user_id = 'gdpr-customer-id';
```

**Step 2: Compact to apply the delete (required if MoR; recommended for CoW too)**
```sql
-- Spark SQL
CALL iceberg.system.rewrite_data_files(
    table   => 'analytics.events',
    where   => 'event_date >= DATE ''2024-01-01''',
    options => map(
        'delete-file-threshold', '1',
        'target-file-size-bytes', '268435456'
    )
);
```

**Step 3: Expire snapshots and remove orphan files from MinIO**
```sql
-- Spark SQL (Spark has no 7-day floor; Trino minimum is 7d)
CALL iceberg.system.expire_snapshots(
    table       => 'analytics.events',
    older_than  => current_timestamp - interval '1' day,
    retain_last => 1
);

CALL iceberg.system.remove_orphan_files(
    table      => 'analytics.events',
    older_than => current_timestamp - interval '3' day
);
```

All three steps are mandatory. Without step 3, deleted bytes remain physically on MinIO — the "GDPR delete" is incomplete.

---

## Decision Guide

| Situation | Mode to use | Action |
|---|---|---|
| File count UP after DELETE | MoR (explicitly set) | Run `rewrite_data_files` with `delete-file-threshold=1` or switch to CoW |
| File count same or down, queries slower | CoW (default), small files after rewrite | Run `optimize` or `rewrite_data_files` after the DELETE |
| Many small per-row deletes arriving continuously | MoR preferred | Schedule hourly `rewrite_data_files` compaction |
| Rare bulk DELETEs, mostly appends | CoW (default) | Run compaction once after each bulk DELETE |
| GDPR / compliance deletion | Either | Always run full 3-step sequence: DELETE → compact → expire → orphan cleanup |
