# Iter104 Q1 — Answer

**Question**: One of our customers is canceling their subscription and invoking what they're calling "the right to be forgotten" — basically they want us to delete all their data from our systems. In Postgres that's straightforward, we just delete rows where tenant_id = their ID. But we've been syncing their events into our analytics setup — a shared Iceberg table that holds data for all our customers mixed together, partitioned by date and tenant ID. How do I actually remove all rows belonging to that one tenant from the Iceberg table? Is there a DELETE statement I can run, and what happens to the underlying files? I'm worried that deleting rows from a file that also contains other tenants' data could corrupt or affect those other rows.

---

## Answer

Yes, you can safely DELETE a tenant from a shared Iceberg table without corrupting other tenants' data. Iceberg uses **delete files** (small marker files) to logically mark rows as deleted without modifying the underlying Parquet files. However, **to actually erase the data from disk** (which GDPR requires), you must run a mandatory three-step sequence in order: DELETE → compaction → expire snapshots. Skipping any step leaves the bytes on MinIO.

### Why Your Corruption Worry Is Unfounded

When you execute:
```sql
DELETE FROM analytics.events WHERE tenant_id = 'departing-customer';
```

Iceberg does **not** rewrite Parquet files. Instead, it creates a **delete file** — a small metadata artifact that marks specific rows as logically deleted. The original Parquet data files remain completely untouched on MinIO, still holding all tenants' data intact. Other tenants' rows in the same file are never modified because the delete file only references your departing customer's specific row positions.

### The Complete GDPR Erasure Sequence

All three steps are required, in this exact order:

**Step 1: Issue the DELETE (instant, safe)**
```sql
DELETE FROM analytics.events WHERE tenant_id = 'departing-customer';
```

This creates delete files marking rows as logically deleted. Rows are now invisible to all queries, but bytes still exist on MinIO. The table size does not drop — this is expected.

**Step 2: Rewrite data files to physically remove the marked rows (Spark SQL)**
```sql
-- Spark SQL only
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.events',
  where   => 'tenant_id = ''departing-customer''',
  options => map(
    'target-file-size-bytes', '268435456',
    'min-input-files',        '1'
  )
);
```

This reads every data file containing deleted rows, copies non-deleted rows (other tenants' data) into new Parquet files, and omits the deleted customer's rows entirely. A new snapshot is committed pointing at the new files.

**Critical caveat:** MinIO storage temporarily **grows** during this step because old files (still referenced by the prior snapshot) remain on disk alongside new files. Storage will drop in step 3.

**Step 3: Expire old snapshots to physically delete unreferenced files (Spark SQL)**
```sql
-- Spark SQL only
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.events',
  older_than  => current_timestamp(),
  retain_last => 1
);

-- Belt-and-suspenders cleanup
CALL iceberg.system.remove_orphan_files(
  table      => 'analytics.events',
  older_than => current_timestamp()
);
```

This marks the prior snapshot as expired and Iceberg issues DELETE calls to MinIO to remove the old Parquet files. **Only after step 3 do bytes actually leave MinIO.**

### Why All Three Steps Are Mandatory

| Skipped step | What goes wrong |
|---|---|
| Skip step 1 | No deletion at all |
| Skip step 2 | Rows logically hidden but original bytes remain in the data files |
| Skip step 3 | Old Parquet files persist on MinIO forever — not GDPR-compliant |

### Partition Safety — Other Tenants Are Protected

Since your table is partitioned by `tenant_id`, Iceberg's partition pruning limits the DELETE and rewrite to only the departing customer's partition. Other tenants' partitions are never touched.

Queries from other tenants running simultaneously are completely safe — Iceberg's snapshot isolation ensures they read the snapshot that was current when their query started.

### Why Use Spark, Not Trino, for Steps 2 and 3

Trino enforces a **7-day minimum-retention floor** on `expire_snapshots` by default. For a true GDPR erasure you need to expire snapshots immediately, not wait 7 days. Use Spark for the rewrite and expire steps.

If you must use Trino, the equivalents are:
```sql
-- Trino — for reference only; 7-day floor may prevent immediate purge
ALTER TABLE iceberg.analytics.events EXECUTE optimize;
ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '0d');
```

Lowering the Trino floor requires changing `iceberg.expire-snapshots.min-retention` in the catalog config and restarting — operationally painful for a one-off erasure. **Use Spark.**

### Verification Steps

After the sequence completes:

1. **Confirm deletion is logical (after step 1):**
   ```sql
   SELECT COUNT(*) FROM analytics.events WHERE tenant_id = 'departing-customer';
   -- Expected: 0
   ```

2. **Verify other tenants unaffected (after step 3):**
   ```sql
   SELECT tenant_id, COUNT(*) AS row_count
   FROM analytics.events
   GROUP BY tenant_id;
   ```
   All other tenants should have their original counts.

3. **Confirm storage dropped**: Monitor MinIO disk usage — it should decrease noticeably after `expire_snapshots` completes.

### Production Timeline

- **Immediately upon request**: Run step 1 (instant, reversible via `rollback_to_snapshot` for ~7 days if needed).
- **Within 24 hours, during off-hours (ingestion paused)**: Run steps 2 and 3.
- **Document**: Log timestamps and step completion for audit/compliance records.
