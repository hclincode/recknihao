# Iter126 Q1 — Answer

**Question**: So we had a bug last week where a batch job accidentally deleted a bunch of rows from one of our Iceberg tables — like maybe 200k events just got wiped out. We caught it pretty fast but by the time we noticed it had already run. In Postgres I would just restore from a backup or maybe use point-in-time recovery, but I don't know if Iceberg works the same way. Is there any way to see what the table looked like before the delete happened, and ideally get those rows back? Or are we just relying on MinIO-level backups?

---

## You can recover those 200k rows using Iceberg's snapshot history.

The good news: **Iceberg is fundamentally different from Postgres in this scenario.** In Postgres you're relying on backup files or WAL replay. In Iceberg, you have something better built in — **snapshot versioning**. Every state change in your table creates an immutable snapshot. You can query the table "as of" any prior snapshot and roll back instantly without touching a single file on MinIO.

### Step 1: Find the snapshot from before the bad delete

Query the table's snapshot history to find the state before your batch job ran:

```sql
SELECT snapshot_id, committed_at, operation, summary
FROM iceberg.analytics."events$snapshots"
ORDER BY committed_at DESC
LIMIT 20;
```

Look for the snapshot with the `committed_at` timestamp **immediately before** your bad delete happened. Note the `snapshot_id` — you'll need it in Step 2. The `$snapshots` metadata table shows the full history of what changed and when.

### Step 2: Roll back to that snapshot (instant, atomic, no data rewrite)

This is the key difference from Postgres. Iceberg's "rollback" is just **moving the table's current-snapshot pointer backward** — it does not rewrite any data files. It's instant and fully ACID:

```sql
-- Must use Spark — Trino 467 does NOT expose a rollback procedure.
CALL iceberg.system.rollback_to_snapshot(
  table       => 'analytics.events',
  snapshot_id => 4823511203987654321  -- replace with the snapshot_id from Step 1
);
```

After this runs, your table is exactly as it was at that snapshot — the 200k deleted rows are back and queryable. **No MinIO files were touched.** The bad snapshot is still in MinIO but no query can reach it because the table's pointer no longer references it.

### Step 3: Understand the retention window

This works **as long as the pre-bad snapshot still exists.** Iceberg keeps snapshots around until you explicitly expire them. Your Trino catalog enforces a **7-day minimum-retention floor** (`iceberg.expire-snapshots.min-retention`, default 7 days) — you cannot expire snapshots younger than 7 days from Trino. So:

- Catch the bad delete within 7 days → rollback works.
- 7+ days after expiry ran → old snapshot is gone, you'd need to re-ingest from Postgres.

**If a correct write happened between the bad delete and when you noticed:** Rolling back also erases that correct write. In that case, instead of rolling back the entire table, use the `overwritePartitions()` pattern to selectively re-ingest only the affected partitions. But given you caught it quickly, a full snapshot rollback is simpler.

### Step 4: Why you don't need MinIO-level backups for this

Iceberg's snapshot history **is** your backup for data-deletion accidents and bad ingestion jobs. You don't need MinIO snapshots or filesystem-level backups to recover from a `DELETE` gone wrong.

**Where MinIO backups still matter:**
- Accidental table drops (`DROP TABLE` removes Iceberg metadata — snapshots are gone).
- Multi-table consistency (Iceberg rolls back one table at a time).
- Ransomware or deliberate MinIO deletion.

For routine data-incident recovery, Iceberg's snapshots are your tool, not MinIO backups.

### Practical next steps

1. **Right now**: query `$snapshots` and find the pre-bad-delete snapshot ID.
2. **Immediately**: run the `rollback_to_snapshot` Spark call above to restore the table.
3. **Debug**: identify which batch job caused the delete. Fix the job before it runs again.
4. **Going forward**: set a 30-day retention threshold on `expire_snapshots` to preserve your rollback window. Run maintenance in order: `rewrite_data_files` nightly → `expire_snapshots` (30-day) → `remove_orphan_files` weekly.
5. **Add a sanity check**: before any batch job commits a large delete, log the row count and compare to expected bounds. A job about to delete 200k rows when only 200 are expected should bail with an alert.
