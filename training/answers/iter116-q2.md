# Iter116 Q2 — Answer

**Question**: One of our enterprise customers just invoked GDPR "right to erasure" and wants us to delete all their personal data within 30 days. In our Iceberg setup, their user records are spread across maybe a dozen tables — `events`, `sessions`, `user_profiles`, `audit_logs`, and others — all partitioned by `tenant_id`. I know Iceberg has some kind of time-travel or snapshot history feature. The problem is: does deleting the data from current rows actually purge it from the historical snapshots too? If a regulator asks us to prove the data is gone, I'm worried the old snapshots still contain the deleted records. How do we actually scrub a user's data completely from Iceberg, including history?

---

## Answer

Your concern is correct and well-founded. **A simple `DELETE` does NOT purge data from Iceberg's historical snapshots.** You need a specific 4-step physical-removal sequence. Here's exactly what to do.

### Why DELETE Alone Isn't Enough

Iceberg uses MVCC (multi-version concurrency control). When you run `DELETE FROM iceberg.analytics.events WHERE tenant_id = 'acme'`, Iceberg writes a **delete file** (a marker listing which rows to ignore) and creates a new snapshot. The original Parquet files containing your customer's personal data remain on MinIO — referenced by older snapshots. A regulator scanning MinIO directly will find those bytes. You are not compliant until you complete the 4-step sequence.

### The 4-Step Physical Removal Sequence

Run these in exact order, on every table holding the tenant's data:

**Step 1: DELETE the rows (logical deletion)**

```sql
-- In Trino or Spark — marks rows as deleted in the current snapshot
DELETE FROM iceberg.analytics.events        WHERE tenant_id = 'acme';
DELETE FROM iceberg.analytics.sessions      WHERE tenant_id = 'acme';
DELETE FROM iceberg.analytics.user_profiles WHERE tenant_id = 'acme';
DELETE FROM iceberg.analytics.audit_logs    WHERE tenant_id = 'acme';
-- ... repeat for all ~12 tables
```

After this: queries return 0 rows for the tenant. But original Parquet bytes are still on MinIO, referenced by older snapshots.

**Step 2: Compact to write new clean Parquet files (apply the deletions physically)**

```python
# Run via Spark (spark-submit or spark-sql)
spark.sql("""
    CALL iceberg.system.rewrite_data_files(
        table => 'analytics.events',
        where => "tenant_id = 'acme'"
    )
""")
# Repeat for all tables
spark.sql("CALL iceberg.system.rewrite_data_files(table => 'analytics.sessions', where => \"tenant_id = 'acme'\")")
spark.sql("CALL iceberg.system.rewrite_data_files(table => 'analytics.user_profiles', where => \"tenant_id = 'acme'\")")
spark.sql("CALL iceberg.system.rewrite_data_files(table => 'analytics.audit_logs', where => \"tenant_id = 'acme'\")")
```

What happens: Spark reads the original files + delete markers, applies the deletions, and writes new clean Parquet files with no trace of the tenant's data. A new snapshot now references only the clean files. BUT: the old snapshots still exist and still reference the old Parquet files on MinIO.

**Step 3: Expire old snapshots — this is the step that physically deletes bytes from MinIO**

```python
# CRITICAL: Run from Spark, NOT Trino.
# Trino enforces a 7-day minimum retention floor and will reject zero-day expiry.
# Spark has no such floor.
spark.sql("""
    CALL iceberg.system.expire_snapshots(
        table        => 'analytics.events',
        older_than   => current_timestamp(),
        retain_last  => 1
    )
""")
# Repeat for all tables
spark.sql("CALL iceberg.system.expire_snapshots(table => 'analytics.sessions', older_than => current_timestamp(), retain_last => 1)")
spark.sql("CALL iceberg.system.expire_snapshots(table => 'analytics.user_profiles', older_than => current_timestamp(), retain_last => 1)")
spark.sql("CALL iceberg.system.expire_snapshots(table => 'analytics.audit_logs', older_than => current_timestamp(), retain_last => 1)")
```

What happens: Iceberg removes all old snapshot metadata entries, then issues S3 DELETE calls against every Parquet file no longer referenced by any surviving snapshot. **After this, the old snapshots are gone — no time-travel to them, and the bytes are deleted from MinIO.** This is the step that makes you GDPR-compliant.

**Step 4: Remove orphan files (belt-and-suspenders sweep)**

```python
spark.sql("""
    CALL iceberg.system.remove_orphan_files(
        table      => 'analytics.events',
        older_than => current_timestamp() - INTERVAL '1' DAY
    )
""")
# Repeat for all tables
```

Catches any Parquet files on MinIO that were never committed to a snapshot (from crashed ingestion jobs). Without this step, a handful of bytes might linger outside the snapshot graph.

### Why Order Matters

| Step | What it does | Without it |
|---|---|---|
| 1. DELETE | Marks rows as logically deleted | Queries return deleted rows |
| 2. rewrite_data_files | Writes new Parquet without tenant data | Old Parquet bytes still on MinIO |
| 3. expire_snapshots | Removes old snapshot references, triggers MinIO file deletions | Old Parquet files remain on MinIO forever (or until retention expires naturally) |
| 4. remove_orphan_files | Cleans up uncommitted files | Orphan Parquet bytes linger on MinIO |

**Most critical**: Step 3 is what actually deletes bytes from MinIO. Steps 1 and 2 without Step 3 do not satisfy GDPR right-to-erasure.

### Trino vs Spark for Step 3

**Always run `expire_snapshots` from Spark for GDPR urgency.** Trino's catalog property `iceberg.expire-snapshots.min-retention` defaults to 7 days and will reject a zero-day expiry with an error. Spark has no minimum retention floor — `retain_last => 1` with `older_than => current_timestamp()` works immediately.

### Watch for Table Properties That Block Expiry

Before running Step 3, check for retention table properties that could silently prevent expiry:

```sql
-- In Trino
SHOW CREATE TABLE iceberg.analytics.events;
-- Look for these properties:
-- 'history.expire.min-snapshots-to-keep' — if set to > 1, override temporarily
-- 'history.expire.max-snapshot-age-ms' — if set to a long retention, override temporarily
```

A property like `'history.expire.min-snapshots-to-keep' = '5'` will override `retain_last => 1` and silently keep 5 snapshots (including ones with the tenant's data). Temporarily unset: `ALTER TABLE iceberg.analytics.events UNSET PROPERTIES ('history.expire.min-snapshots-to-keep')`, then run the expiry, then restore.

### Verification Checklist (For the Regulator)

After all four steps complete on all tables:

```sql
-- 1. Query layer: no rows visible
SELECT COUNT(*) FROM iceberg.analytics.events WHERE tenant_id = 'acme';
-- Expected: 0

-- 2. Snapshot layer: only one snapshot remaining (current clean state)
SELECT COUNT(*) FROM iceberg.analytics."events$snapshots";
-- Expected: 1

-- 3. File layer: no files reference the deleted tenant's partition
SELECT COUNT(*) FROM iceberg.analytics."events$files"
WHERE partition.tenant_id = 'acme';
-- Expected: 0

-- 4. Repeat verification for all ~12 tables
```

Then scan a sample of the new Parquet files on MinIO to confirm no records for the tenant are present. Document the verification timestamp for the regulator's audit log.

### Important Gotcha: Never Use DROP PARTITION for Per-User Erasure

`DELETE FROM ... WHERE tenant_id = 'acme'` correctly targets one tenant's rows. Do NOT use partition-level operations for per-user deletion inside a shared table — they would delete every tenant's data for that partition.

### Timeline

You have 30 days. The 4-step sequence completes in minutes to hours (depending on table size and count). Recommend completing within the first week and re-verifying at Day 28 so you have time to troubleshoot before the deadline.
