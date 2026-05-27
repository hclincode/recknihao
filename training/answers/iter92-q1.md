# Iter92 Q1 — Answer

**Question**: Enterprise customer sent a GDPR deletion request. What is the proper process to purge all their data from Iceberg, and how do you prove to auditors the data is gone?

---

## Answer

**Critical first: do NOT delete files directly from MinIO.** That corrupts Iceberg's metadata layer and breaks your table. Iceberg uses an immutable-file model where metadata tracks which files belong to which snapshots. Direct deletion orphans references and causes "file not found" errors.

## The 4-Step Purge Sequence (in this exact order)

### Step 1: DELETE the rows

```sql
-- Trino:
DELETE FROM iceberg.analytics.events WHERE tenant_id = 'acme';

-- Verify immediately:
SELECT COUNT(*) FROM iceberg.analytics.events WHERE tenant_id = 'acme';
-- Result must be: 0
```

After this runs, queries return 0 rows. **But the original Parquet files containing the deleted rows are still sitting on MinIO.** Iceberg marks the deletes via delete files or copy-on-write rewrites, but the old bytes aren't physically gone yet.

### Step 2: `rewrite_data_files` — apply pending deletes to Parquet files

```sql
-- Spark SQL (rewrite_data_files with where clause for this tenant's partition):
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.events',
  where   => 'tenant_id = ''acme''',
  options => map('target-file-size-bytes', '268435456')
);
```

This forces Iceberg to rewrite the data files, physically removing the deleted rows from Parquet and creating new clean files without the tenant's data. The old files (still containing the bytes) remain on MinIO but are no longer in the current snapshot.

### Step 3: `expire_snapshots` — orphan the old data files

```sql
-- Spark SQL (use Spark, not Trino — Trino enforces a 7-day minimum retention floor):
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.events',
  older_than  => current_timestamp - interval '0' day,
  retain_last => 1
);
```

**Important:** Trino 467 enforces a 7-day minimum retention floor on `expire_snapshots` (via `iceberg.expire-snapshots.min-retention`). For GDPR where you need immediate deletion, **use Spark** which does not enforce this floor.

After this step, the old snapshots disappear from `$snapshots`. The old data files are now unreferenced — no live snapshot points to them.

### Step 4: `remove_orphan_files` — physically delete from MinIO

```sql
-- Spark SQL:
CALL iceberg.system.remove_orphan_files(
  table      => 'analytics.events',
  older_than => current_timestamp - interval '0' day
);
```

Again, use Spark for immediate deletion (Trino has a 7-day floor). This scans MinIO for any Parquet file that no current snapshot references and issues DELETE calls to remove them. The tenant's original Parquet bytes are now physically gone from MinIO.

## Why Each Step Is Necessary

- **Step 1 alone:** queries return 0 rows, but bytes remain on MinIO. Not GDPR-compliant.
- **Steps 1+2 alone:** compaction creates new clean files, but old files are still referenced by older snapshots (Iceberg can time-travel to them).
- **Steps 1+2+3 alone:** old snapshots expired, old files orphaned in metadata, but the S3 objects are not deleted yet.
- **All four steps:** the bytes actually leave MinIO. GDPR-compliant.

## How to Prove the Data is Gone (for auditors)

**Do NOT use time-travel queries to prove deletion** — that proves the old data still exists in old snapshots, which is the opposite of what you want.

**Verification 1: Row count is zero**
```sql
SELECT COUNT(*) FROM iceberg.analytics.events WHERE tenant_id = 'acme';
-- Must return: 0
```

**Verification 2: No snapshots reference the old data**
```sql
SELECT snapshot_id, committed_at, operation
FROM iceberg.analytics."events$snapshots"
ORDER BY committed_at DESC LIMIT 20;
```
After `expire_snapshots` runs, old snapshots no longer appear here. This proves the historical versions containing the tenant's data are gone.

**Verification 3: No files contain the tenant's partition**
```sql
-- After removal, events$files should show zero rows for the acme partition:
SELECT COUNT(*) FROM iceberg.analytics."events$files"
WHERE partition.tenant_id = 'acme';
-- Must return: 0
```

## Written GDPR Deletion Report Template

```
Customer: Acme Inc (tenant_id = 'acme')
Deletion Request Date: [date]
Deletion Completed: [date]

Step 1 (DELETE): [date]
  Query: DELETE FROM iceberg.analytics.events WHERE tenant_id = 'acme'
  Rows deleted: [row count from query log]

Step 2 (rewrite_data_files): [date]
  Procedure rewrite_data_files executed on analytics.events WHERE tenant_id = 'acme'
  Old files containing deleted rows rewritten and excluded from current snapshot.

Step 3 (expire_snapshots): [date]
  Procedure expire_snapshots executed with older_than = [timestamp], retain_last = 1
  Snapshots containing Acme data expired and removed from snapshot history.

Step 4 (remove_orphan_files): [date]
  Procedure remove_orphan_files executed with older_than = [timestamp]
  Unreferenced Parquet files containing Acme data physically deleted from MinIO.

Verification:
  SELECT COUNT(*) FROM analytics.events WHERE tenant_id = 'acme' => 0
  SELECT COUNT(*) FROM analytics."events$files" WHERE partition.tenant_id = 'acme' => 0
  No snapshots in $snapshots reference Acme data.
```

## The Single Most Common Mistake

Running DELETE, verifying COUNT = 0, and telling lawyers "done." This is **not GDPR-compliant.** The original Parquet bytes are still on MinIO, recoverable by restoring old snapshots. An auditor who scans your MinIO bucket will find the customer's data.

Iceberg's MVCC model is excellent for analytics but means deletions are a four-step process with no shortcut.
