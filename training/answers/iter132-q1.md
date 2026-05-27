# Iter132 Q1 — Answer

**Question**: "We have a customer who sent us a GDPR deletion request — they want all their data gone, permanently, not just hidden. In Postgres this is easy: you run a DELETE, it's gone. But we're storing their events in Iceberg on MinIO now. I know Iceberg has this concept of snapshots for time travel, so even if I delete the rows from the current table, aren't they still sitting in the old Parquet files on disk? How do I actually make sure the data is truly, physically gone from our object storage in a way I could prove to a regulator? What does that process actually look like step by step?"

---

## The Hard Truth: DELETE Alone Is Not GDPR-Compliant

You're correct — running `DELETE FROM iceberg.analytics.events WHERE tenant_id = 'acme'` and confirming `SELECT COUNT(*)` returns 0 is **not** GDPR-compliant. After a DELETE, the original Parquet bytes are still sitting on MinIO. Here's why, and the four-step sequence to actually get them gone.

### Why Iceberg's Time-Travel Architecture Defeats a Simple DELETE

Iceberg is built on **immutable Parquet files** and MVCC (multi-version concurrency control). Every operation creates a new **snapshot** — a point-in-time version of the table that points to a set of Parquet files via metadata. When you run a DELETE:

1. Iceberg creates a **delete file** (a small marker listing which rows to skip).
2. A new snapshot is created that references both the original Parquet files AND the delete markers.
3. The **prior snapshot still exists** and still references the original Parquet files without any deletion markers.

From the query layer, `SELECT * FROM iceberg.analytics.events` sees the current snapshot (delete markers applied), so the rows appear gone. But the original Parquet files containing the customer's bytes remain physically on MinIO, referenced by the prior snapshot. A privacy auditor who lists MinIO directly with `mc ls --recursive` will still find those files and can read the customer's data. That's the regulatory violation.

---

## The 4-Step Physical Removal Sequence

Complete **all four steps, in order, for every Iceberg table** that contains the customer's data. A typical SaaS has many tables carrying `tenant_id` (events, orders, users, sessions, audit logs, etc.) — each one stores the customer's bytes independently and each needs its own full 4-step pass. Skipping even one table is a GDPR violation.

### Step 1: DELETE the rows (Trino or Spark SQL)

```sql
DELETE FROM iceberg.analytics.events WHERE tenant_id = 'acme';
```

**What happens on disk:** Iceberg creates small delete files (position markers listing which row numbers in each Parquet file should be ignored). The original Parquet data files are untouched. `SELECT COUNT(*) WHERE tenant_id = 'acme'` returns 0 immediately because delete markers are applied at read time — but the bytes are still on MinIO.

### Step 2: Compact and apply deletes into new clean Parquet files (Spark required)

```sql
-- Run via spark-submit or Spark SQL session
CALL iceberg.system.rewrite_data_files(
  table => 'analytics.events',
  where => "tenant_id = 'acme'"
);
```

**What happens on disk:** Spark reads each affected Parquet file plus the delete files, applies deletions in memory, and writes **new** Parquet files without the customer's rows. A new snapshot now points at these new files. But the old Parquet files (still containing the customer's bytes) remain on MinIO because the previous snapshot still references them. Storage usage temporarily **increases** at this point — you now have both old and new files. The cleanup comes next.

> **Why Spark instead of Trino's OPTIMIZE?** Trino's native `ALTER TABLE ... EXECUTE optimize` has confirmed bugs after partition spec changes (trinodb/trino issues #26109, #26503, #25279), and a `WHERE tenant_id = 'acme'` clause may not meet Trino's whole-partition optimization condition. Use Spark `rewrite_data_files` for guaranteed correctness here.

### Step 3: Expire old snapshots — this is the step that physically removes bytes from MinIO (Spark required for zero-day urgency)

```sql
-- Run via spark-submit or Spark SQL session
-- IMPORTANT: Trino enforces a 7-day minimum retention floor on expire_snapshots.
-- Trino REJECTS older_than < 7 days. For GDPR urgency (delete NOW, not in 7 days),
-- use Spark — which has no minimum-retention floor.
CALL iceberg.system.expire_snapshots(
  table        => 'analytics.events',
  older_than   => current_timestamp() - INTERVAL '0' DAY,
  retain_last  => 1
);
```

**What happens on disk — the critical step:** The procedure walks Iceberg's metadata tree, identifies all data files, delete-marker files, manifest files, and manifest-list files referenced only by expired snapshots, and **issues S3 DELETE calls directly against MinIO** for every unreferenced file. After this step:

- Original Parquet files containing the customer's bytes are deleted from MinIO.
- Delete-marker files from step 1 are deleted.
- All manifest files and manifest-list files indexing those deleted files are deleted.
- Prior snapshots are removed from the table's metadata.

Only after this step are the bytes **physically gone from object storage**. This is what makes you GDPR-compliant at the storage layer.

**Pre-flight: check for snapshot retention table properties that might override your `retain_last => 1`:**

```sql
-- Look for history.expire.min-snapshots-to-keep and history.expire.max-snapshot-age-ms
SHOW CREATE TABLE iceberg.analytics.events;

-- If either is set, unset them before the GDPR purge:
ALTER TABLE iceberg.analytics.events
  UNSET TBLPROPERTIES (
    'history.expire.min-snapshots-to-keep',
    'history.expire.max-snapshot-age-ms'
  );

-- ... run steps 1–4 ...

-- Then restore afterward:
ALTER TABLE iceberg.analytics.events
  SET TBLPROPERTIES (
    'history.expire.min-snapshots-to-keep' = '5',
    'history.expire.max-snapshot-age-ms'   = '432000000'
  );
```

If the table has `history.expire.min-snapshots-to-keep = 5` and you skip this check, your `retain_last => 1` silently becomes "retain max(1, 5) = 5 snapshots" — the old snapshots (and the customer's bytes) survive. You'll think the purge succeeded when it didn't.

### Step 4: Sweep MinIO for orphan files (Spark)

```sql
-- Run via spark-submit or Spark SQL session
-- Orphan files: Parquet bytes written to MinIO but never committed to any snapshot
-- (e.g., from a Spark job that crashed mid-write writing that tenant's events).
-- For GDPR urgency, 1 day is safe if you've paused ingestion (see below).
CALL iceberg.system.remove_orphan_files(
  table       => 'analytics.events',
  older_than  => current_timestamp() - INTERVAL '1' DAY
);
```

**What happens on disk:** Scans the MinIO prefix where the table lives, builds a list of all files referenced by any live manifest, and deletes any file in the prefix not in that set. This catches files left from a partially-failed ingestion job that was writing the deleted tenant's events — **even if never committed to any snapshot, those files still contain the customer's bytes.**

**Before running step 4:**
- **Pause all ingestion jobs** so no files are mid-write. On Kubernetes: scale Spark deployments to 0 replicas. Resume after step 4 completes.
- **Drop any export tables** if you created `CREATE TABLE iceberg.exports.customer_offboard AS SELECT ...` for data handoff. The 4-step purge on `analytics.events` doesn't touch that separate table — forgetting to drop it leaves a full copy of the customer's data behind.

---

## The Complete Runbook

```sql
-- ========================================================================
-- GDPR RIGHT-TO-BE-FORGOTTEN PURGE
-- Customer: Acme Inc (tenant_id = 'acme')
-- Run via spark-submit or Spark SQL session.
-- ========================================================================

-- PREFLIGHT: Pause ingestion (Kubernetes: scale to 0, Airflow: pause DAG)

-- STEP 1: Delete the rows
DELETE FROM iceberg.analytics.events WHERE tenant_id = 'acme';

-- STEP 2: Compact — apply deletes, write clean Parquet files
CALL iceberg.system.rewrite_data_files(
  table => 'analytics.events',
  where => "tenant_id = 'acme'"
);

-- STEP 3: Expire old snapshots — physically removes bytes from MinIO
-- CAUTION: Irreversible — no time-travel to pre-deletion state after this.
CALL iceberg.system.expire_snapshots(
  table        => 'analytics.events',
  older_than   => current_timestamp() - INTERVAL '0' DAY,
  retain_last  => 1
);

-- STEP 4: Sweep orphan files from MinIO
CALL iceberg.system.remove_orphan_files(
  table       => 'analytics.events',
  older_than  => current_timestamp() - INTERVAL '1' DAY
);

-- POSTFLIGHT: Resume ingestion (Kubernetes: scale back up, Airflow: unpause DAG)
-- REPEAT: Run all four steps for every table with tenant data.
```

---

## Verification — Proving to a Regulator the Data Is Gone

### 1. Query layer (proves current state)

```sql
-- Must return 0 rows on every table
SELECT COUNT(*) FROM iceberg.analytics.events WHERE tenant_id = 'acme';
```

### 2. Metadata layer (proves no snapshots reference the data)

```sql
-- Confirm only the post-purge snapshot exists
-- If older snapshots appear, step 3 didn't fully expire them
SELECT snapshot_id, committed_at, operation
FROM iceberg.analytics."events$snapshots"
ORDER BY committed_at;
-- Expected: 1 row (the current snapshot)

-- If partitioned by tenant_id, confirm no files remain for that partition
SELECT file_path, record_count
FROM iceberg.analytics."events$files"
WHERE partition.tenant_id = 'acme';
-- Expected: 0 rows
```

### 3. Storage layer — the regulator-grade proof

```bash
# List the table's MinIO prefix. If the customer's bytes are truly gone,
# any remaining Parquet files belong to other tenants only.
mc ls --recursive minio/lakehouse/warehouse/analytics/events/

# Or use the MinIO web console to navigate to the table prefix and confirm
# no files are dated before your purge timestamp.
```

If Parquet files remain after step 4, the purge didn't complete. The presence of a file at object-storage level is what a privacy auditor will check — it's the final, unambiguous proof.

---

## Final Checklist Before Sign-Off

1. **Every table with `tenant_id` data** — ran all four steps on each one (events, orders, users, sessions, audit logs, invoices)?
2. **Retention properties** — checked for `history.expire.min-snapshots-to-keep` and `history.expire.max-snapshot-age-ms` before step 3? Unset if needed?
3. **Export tables** — dropped any `iceberg.exports.customer_*` tables created for data handoff?
4. **Query layer** — `SELECT COUNT(*) WHERE tenant_id = 'acme'` returns 0 on every table?
5. **Storage layer** — `mc ls --recursive` on the MinIO prefix for each table shows no files with that tenant's partition, or a spot-check of remaining files confirms they don't contain that tenant's data?

Once all five pass, you have the chain of evidence for a GDPR regulator: the query returns nothing, the snapshot metadata shows the old data is expired, and the storage layer has no files containing those bytes.
