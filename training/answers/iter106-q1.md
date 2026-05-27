# Iter106 Q1 — Answer

**Question**: We have about 90 tenants, and we just found out that one of our biggest customers is moving to a competitor. They want all their data out of our system within 5 business days per their contract. The problem is all our tenants share the same Iceberg events table — tenant data isn't in separate tables, it's all mixed together with a `tenant_id` column. Our legal team is asking us to confirm in writing that their data has been fully removed from our storage. How do we actually export their data to give back to them, and then make sure we've completely deleted every byte from our system? I'm worried about all the things that could silently hold onto their data even after we think we've deleted it.

---

## Answer

A naive `DELETE FROM events WHERE tenant_id = 'customer'` is not enough. After that statement, the customer's bytes are still on MinIO — held by old snapshots and unreferenced orphan files. The complete sequence is: **export → DELETE → rewrite → expire snapshots → remove orphan files → verify**. All steps are required and must run in this order.

### Step 1: Export the Customer's Data (Day 1)

```sql
-- Trino: create a dedicated export table in Iceberg
CREATE SCHEMA IF NOT EXISTS iceberg.exports;

CREATE TABLE iceberg.exports.customer_offboard AS
  SELECT * FROM iceberg.analytics.events
  WHERE tenant_id = 'departing-customer';
```

The export files land on MinIO at a known path (e.g., `s3a://warehouse/exports/customer_offboard/`). Your customer's technical team can download the Parquet files via the MinIO S3 API. Once they confirm receipt, clean up the export table.

### Step 2: DELETE the Rows (Day 1)

```sql
-- Trino: mark rows as deleted
DELETE FROM iceberg.analytics.events
WHERE tenant_id = 'departing-customer';
```

This creates **position delete files** — small markers saying "this row is deleted." The original Parquet data files are NOT rewritten. The customer's bytes are still on MinIO. Queries no longer return these rows, but the data is not gone.

### Step 3: Rewrite Data Files to Remove Bytes (Day 2 — Spark SQL)

```sql
-- Spark SQL only (Trino's EXECUTE optimize cannot process MoR position delete files)
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.events',
  where   => 'tenant_id = ''departing-customer''',
  options => map('target-file-size-bytes', '268435456', 'min-input-files', '1')
);
```

This reads every file containing deleted rows, copies the surviving rows (other tenants' data) into new Parquet files, and commits a new snapshot. The customer's data is absent from the new files. But the old Parquet files — still referenced by prior snapshots — remain on MinIO. Storage temporarily grows during this step (old + new files coexist).

### Step 4: Expire Old Snapshots (Day 2 — Spark SQL)

```sql
-- Spark SQL only — Trino enforces a 7-day minimum floor on expire_snapshots
-- For a 5-day legal deadline, you MUST use Spark, not Trino
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.events',
  older_than  => current_timestamp,
  retain_last => 1
);
```

This removes the old snapshot entries that pointed at the pre-rewrite Parquet files. Old snapshots can no longer keep those files alive. **After this step, the old Parquet files become orphans** — no snapshot references them, but they still physically exist on MinIO until step 5.

> **Why Spark and not Trino?** Trino enforces `iceberg.expire-snapshots.min-retention = 7d` by default. Running this from Trino would refuse to expire snapshots younger than 7 days — too slow for a 5-day compliance deadline. Use Spark, which has no retention floor.

### Step 5: Remove Orphan Files from MinIO (Day 3)

```sql
-- Spark SQL: physically delete unreferenced files from MinIO
CALL iceberg.system.remove_orphan_files(
  table      => 'analytics.events',
  older_than => current_timestamp - interval '1' day
);
```

This scans the MinIO bucket for Parquet files that no current snapshot references, then issues S3 `DELETE` calls against MinIO to physically remove them. **Only after this step do bytes actually leave MinIO storage.**

The `older_than` guard (1 day) prevents accidental deletion of files from in-flight writes. For a compliance purge, 1 day is safe.

### Step 6: Verify — Prove Every Byte Is Gone (Day 3-4)

**Row count (should be zero):**
```sql
SELECT COUNT(*) FROM iceberg.analytics.events
WHERE tenant_id = 'departing-customer';
-- Expected: 0
```

**Metadata table check (no files reference this tenant):**
```sql
SELECT COUNT(*) FROM iceberg.analytics."events$files"
WHERE partition.tenant_id = 'departing-customer';
-- Expected: 0

-- Also confirm partition is absent from the partition listing
SELECT partition.tenant_id, record_count
FROM iceberg.analytics."events$partitions"
ORDER BY record_count DESC;
-- 'departing-customer' must not appear
```

**MinIO filesystem check:**
```bash
# List all objects in the events table location
aws s3 ls s3://warehouse/analytics/events/ --recursive \
  | grep -i "departing-customer"
# Must return zero results
```

**Snapshot count check:**
```sql
SELECT COUNT(*) FROM iceberg.analytics."events$snapshots";
-- Should be dramatically lower than before — ideally just 1
```

### What Silently Holds Data After a Naive DELETE

| Silent holder | What it is | Cleared by |
|---|---|---|
| **Position delete files** | Marker files saying "row X is deleted" | `rewrite_data_files` (merges them away) |
| **Old snapshots** | Prior table versions pointing to pre-delete Parquet files | `expire_snapshots` |
| **Orphaned Parquet files** | Old data files abandoned after rewrite; no snapshot references them | `remove_orphan_files` |
| **Failed-write orphans** | Files from crashed Spark jobs that never committed | `remove_orphan_files` |

> **Why order matters**: If you run `remove_orphan_files` before `expire_snapshots`, the old Parquet files are still referenced by live (but about to be expired) snapshots. `remove_orphan_files` never deletes referenced files, so it would skip them. The correct order is: rewrite → expire → orphan cleanup.

### Legal Confirmation Template

For your legal team:

> "On [DATE], we executed a compliant data deletion for tenant [CUSTOMER_ID] from our Iceberg analytics system:
> 1. **Export**: All rows exported to [MinIO path] for customer download. Download confirmed [DATE].
> 2. **Logical delete**: `DELETE FROM events WHERE tenant_id = '[CUSTOMER_ID]'` executed [DATE], snapshot ID [N].
> 3. **Physical rewrite**: `rewrite_data_files` completed [DATE] — new Parquet files contain zero rows for [CUSTOMER_ID].
> 4. **Snapshot expiry**: `expire_snapshots(retain_last => 1)` completed [DATE] — [N] snapshots removed.
> 5. **Orphan file removal**: `remove_orphan_files` completed [DATE] — [N] files, [X] GB reclaimed from MinIO.
> 6. **Verification**: Zero rows returned by row-count query; zero files returned by `$files` metadata query; zero objects returned by S3 listing.
>
> As of [DATE], zero bytes of [CUSTOMER_ID] data exist on any live snapshot or MinIO storage."

### Timeline for 5-Day Deadline

- **Day 1**: Export + DELETE (both fast, minutes to an hour)
- **Day 2**: `rewrite_data_files` (may take 1-3 hours for a large tenant partition; schedule during low-ingestion window) → `expire_snapshots` immediately after
- **Day 3**: `remove_orphan_files` → verification queries + MinIO listing
- **Day 4**: Deliver verification evidence to legal team
- **Day 5**: Buffer for any issues
