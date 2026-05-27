# Iter78 Q2 — Answer

**Question**: Customer invoked GDPR right to erasure. Running `DELETE WHERE tenant_id = 'their-id'` — is the data actually gone? Do Iceberg snapshots mean it persists? What's the full cleanup sequence?

---

## Answer

Your concern is legitimate — a simple `DELETE` is not sufficient for GDPR compliance with Iceberg. You need three steps in sequence for the data to be truly gone from MinIO.

### Why DELETE alone isn't enough

When you run:

```sql
DELETE FROM analytics.events WHERE tenant_id = 'their-id';
```

Iceberg does not modify or delete the original Parquet files on MinIO. Instead, it:
1. Creates a **delete file** — a small marker saying "ignore these rows in these data files"
2. Creates a **new snapshot** pointing to the updated table state
3. Leaves the original Parquet files containing the customer's data physically intact on MinIO

The customer's rows are invisible to normal queries (the current snapshot's delete files mask them), but the raw data bytes are still on disk. For GDPR purposes, this isn't erasure.

### Why old snapshots make it worse

Every write operation creates a snapshot. Old snapshots still reference the original data files. Iceberg's garbage collector explicitly protects files referenced by any live snapshot — it won't delete them.

So even after your DELETE, old snapshots from before the deletion still point to the original data files containing the customer's data. Those files stay on MinIO as long as those snapshots exist.

### The full four-step sequence

**Step 1: Run the DELETE**

```sql
DELETE FROM iceberg.analytics.events WHERE tenant_id = 'their-id';
```

Run any table that holds this tenant's data. This marks rows as deleted in the current snapshot.

**Step 2: Rewrite data files** (removes delete markers by rewriting Parquet without the deleted rows)

```sql
-- Run in Spark SQL
CALL iceberg.system.rewrite_data_files(
  table => 'analytics.events',
  where => 'tenant_id = ''their-id'''
);
```

This physically rewrites the affected Parquet files with the deleted rows excluded. After this step, the data bytes no longer exist in any active file — but old snapshots may still reference the pre-rewrite files.

**Step 3: Expire old snapshots**

```sql
-- Run in Spark SQL
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.events',
  older_than  => current_timestamp,
  retain_last => 1
);
```

This removes all snapshots except the current one. Once a snapshot is expired, the data files it referenced (but the current snapshot doesn't) become orphaned — no longer protected by Iceberg's garbage collector.

**Step 4: Remove orphan files**

```sql
-- Run in Spark SQL
CALL iceberg.system.remove_orphan_files(
  table      => 'analytics.events',
  older_than => current_timestamp - interval '1' hour
);
```

This physically deletes from MinIO any Parquet files no snapshot references. After this step, the customer's data is truly gone.

### Important notes

**Steps 2–4 are Spark-only** — `CALL iceberg.system.*` procedures work in Spark SQL, not in Trino. You'll need to submit them via `spark-submit` or a Spark session, not through Trino.

**You lose time-travel for the affected table** — expiring snapshots with `retain_last => 1` means you can't roll back to states before the deletion. This is necessary for GDPR compliance.

**Run during low-traffic windows** — avoid running `rewrite_data_files` and `remove_orphan_files` concurrently with active ingestion jobs. Schedule for a maintenance window (e.g., Sunday early morning).

**Backups and replicas are separate** — if your MinIO setup has point-in-time backups or replication, those also contain the customer's data. Your GDPR process must address backups separately.

### How to verify the data is truly gone

After all four steps:

```sql
-- Confirm no rows remain (run in Trino)
SELECT COUNT(*) FROM iceberg.analytics.events WHERE tenant_id = 'their-id';
-- Expected: 0

-- Confirm only the current snapshot remains
SELECT snapshot_id, committed_at, operation
FROM iceberg.analytics."events$snapshots"
ORDER BY committed_at DESC;
-- Expected: 1 row (the current snapshot)
```

Document these verification queries and their output as evidence of compliance.

### Summary

| Step | What it does | Required for GDPR? |
|---|---|---|
| `DELETE` | Marks rows deleted in current snapshot | Yes, but insufficient alone |
| `rewrite_data_files` | Rewrites Parquet files without deleted rows | Yes |
| `expire_snapshots` | Removes old snapshots that reference old files | Yes |
| `remove_orphan_files` | Physically deletes unreferenced files from MinIO | Yes — this is when data is truly gone |
