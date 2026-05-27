# Iter71 Q1 — Answer

**Question**: One of our customers churned last month and now they've sent us a formal GDPR "right to be forgotten" request. We need to delete all their data. The problem is we have a single shared `analytics.events` table in Iceberg that holds events for all our tenants together, partitioned by date. Their data is scattered across two years of daily partitions — there's no single partition that only has their rows.

My first instinct was to just delete the Parquet files for that tenant directly off MinIO, but I'm not sure if that would break something since Iceberg probably has its own tracking of what files exist. My second idea was to delete the date partitions that contain their data, but that would wipe out the same date partitions for all our other tenants too, which obviously can't be right.

So what's the actual correct way to do a targeted row-level delete for one tenant across a shared table like this? I've seen something about Iceberg having a "delete" operation but I don't understand if that actually removes the bytes from storage or just hides the rows at query time. And if it just hides them, what extra steps do I need to take so I can actually tell a GDPR auditor that the data is physically gone from our MinIO storage?

---

## Answer

### (a) How to do a targeted row-level delete without wiping other tenants

The correct pattern is a row-level `DELETE` scoped to the specific tenant:

```sql
DELETE FROM iceberg.analytics.events WHERE tenant_id = 'acme';
```

This is the only safe way. Your second instinct — deleting date partitions — would wipe every tenant's data for those dates. Iceberg partitions are physical file groupings that hold rows from all tenants active on a given day. If you delete `WHERE day = '2025-02-23'`, you delete customer A, B, and C's data all at once.

The row-level DELETE is safe because it's tenant-scoped and leaves other customers' partitions untouched.

### (b) Is deleting Parquet files directly off MinIO safe?

**Absolutely not. Never do this.** Iceberg maintains metadata (manifests and snapshots) that tracks which Parquet files belong to the table. When you delete files directly from MinIO:

1. The metadata still points to the now-missing files — your next query fails with "file not found" errors mid-scan.
2. Iceberg's snapshot history is corrupted, making time-travel and rollbacks impossible.
3. The Hive Metastore and MinIO are now in an inconsistent state — exactly what Iceberg is designed to prevent.

Always use Iceberg's own operations. Never touch MinIO directly to manage table data.

### (c) Do Iceberg row deletes actually remove bytes from storage or just hide rows at query time?

This is the critical insight for GDPR compliance: **a DELETE only hides rows at query time. The original bytes stay on MinIO.**

When you run `DELETE FROM iceberg.analytics.events WHERE tenant_id = 'acme'`, Iceberg creates a new snapshot with **delete files** — small marker files that say "ignore these row positions in those Parquet files." The original Parquet data files are completely untouched on MinIO.

A `SELECT COUNT(*) WHERE tenant_id = 'acme'` returns 0, but the bytes are still sitting in object storage, referenced by older snapshots. If a privacy auditor runs `mc ls --recursive` on your MinIO bucket, they will still find Parquet files containing your deleted customer's data. **This is a GDPR violation.**

### (d) What additional steps physically remove the data so an auditor is satisfied

You must run all four steps in order:

**Step 1: DELETE the rows (Trino or Spark)**
```sql
DELETE FROM iceberg.analytics.events WHERE tenant_id = 'acme';
```
Result: delete files written, original Parquet still on MinIO.

**Step 2: Rewrite data files to compact away delete markers (Spark only)**
```sql
CALL iceberg.system.rewrite_data_files(
  table => 'analytics.events',
  where => "tenant_id = 'acme'"
);
```
Spark reads the affected Parquet files plus the delete files, applies the deletes in memory, and writes new Parquet files without the deleted tenant's rows. The old files are still on MinIO because the previous snapshot still references them.

**Step 3: Expire snapshots to make old files unreferenced (Spark only)**
```sql
CALL iceberg.system.expire_snapshots(
  table        => 'analytics.events',
  older_than   => current_timestamp() - INTERVAL '0' DAY,
  retain_last  => 1
);
```
This is the step that physically removes the bytes. Iceberg walks its snapshot tree, finds Parquet files no longer referenced by any live snapshot, and issues DELETE calls to MinIO. Only after this step are the original bytes physically gone.

The aggressive `INTERVAL '0' DAY` is specific to GDPR work — it removes all old snapshots immediately, making the deletion irreversible. For routine maintenance you'd use `INTERVAL '7' DAY` to keep a rollback window.

**Step 4: Remove orphan files as final cleanup (Spark only)**
```sql
CALL iceberg.system.remove_orphan_files(
  table       => 'analytics.events',
  older_than  => current_timestamp() - INTERVAL '1' DAY
);
```
During ingestion, jobs sometimes crash between writing a Parquet file and committing it to a snapshot. Those orphaned files sit on MinIO unreferenced by any snapshot — Step 3 won't find them. If any crashed ingestion job was writing the deleted tenant's events, that orphan file still contains their data. This step scans MinIO for unreferenced files and deletes them. The `INTERVAL '1' DAY` buffer protects in-flight writes from active ingestion jobs.

### The complete compliance checklist

After running steps 1–4, verify:

1. **Query layer**: `SELECT COUNT(*) FROM iceberg.analytics.events WHERE tenant_id = 'acme'` returns 0.
2. **Metadata layer**: Query `iceberg.analytics."events$files"` — confirm no files remain with `partition.tenant_id = 'acme'`.
3. **Storage layer**: `mc ls --recursive minio/lakehouse/warehouse/analytics/events/` — confirm no Parquet files contain the deleted tenant's data.

Only after all three pass should you sign off to the auditor.

### Why the obvious workflows fail

| Approach | Why it fails |
|---|---|
| Run DELETE, verify COUNT=0, sign off | Bytes still on MinIO in old snapshots — GDPR violation |
| Drop date partitions containing tenant data | Deletes ALL tenants' data for those dates |
| Delete Parquet files directly from MinIO | Corrupts Iceberg metadata, breaks queries |
| DELETE + rewrite_data_files only (skip step 3) | Old snapshots still reference original files |
| Skip step 4 (remove_orphan_files) | Orphan files from crashed ingest jobs still hold tenant data |

### Production details

- All `CALL iceberg.system.*` statements run in **Spark SQL only**, not Trino. Submit via `spark-submit` or a Kubernetes Job.
- These steps are legally required for GDPR right-to-erasure compliance — not optional.
- Running Step 3 with `retain_last=1` and `older_than=now()` makes the deletion irreversible. Confirm the tenant's request is valid before running.
