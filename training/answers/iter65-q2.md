# Iter65 Q2 — Answer

**Question**: A customer just cancelled their subscription and under our contract and GDPR we have a legal obligation to delete all of their data within 30 days. Their data is stored in Iceberg tables that are shared with other tenants — everything is in the same table, just filtered by `tenant_id`. How do I actually delete all rows for a specific `tenant_id` from an Iceberg table? I know a regular DELETE in a normal database is straightforward, but I've heard that in these kinds of storage systems the old data can hang around in files even after you delete it. Is that true? What do I need to do to make sure the data is actually gone — not just hidden from queries but really purged from storage — so we can tell a regulator it's been deleted?

---

## Answer

Yes, it's true. A simple `DELETE` leaves the customer's bytes sitting on MinIO. To be GDPR-compliant, you must run a specific 4-step sequence that physically removes the data from storage. Here's what you need to know.

### Why a simple DELETE is not enough

Iceberg uses **MVCC** (multi-version concurrency control). Every write to an Iceberg table creates an immutable snapshot, and old snapshots are kept so you can rewind or replay data. When you run `DELETE FROM iceberg.analytics.events WHERE tenant_id = 'acme'`, Iceberg doesn't erase the customer's Parquet data files. Instead, it writes a small **delete file** — a marker that says "ignore these rows in these data files." The original Parquet files containing Acme's raw bytes stay on MinIO, referenced by older snapshots, until you explicitly remove those snapshots.

A regulator running `mc ls --recursive` against your MinIO storage will still find Acme's data bytes sitting there, even though `SELECT COUNT(*) WHERE tenant_id = 'acme'` returns zero. You are not compliant until those bytes are physically gone.

### The 4-step physical-removal sequence

Run these **in this order**. Each step builds on the previous one.

**Step 1: DELETE the rows**

Run this in Trino or Spark SQL — either works:

```sql
DELETE FROM iceberg.analytics.events WHERE tenant_id = 'acme';
```

What this does: Iceberg creates a new snapshot that references **delete files** — small markers listing which rows to skip. The original Parquet data files are untouched. Queries return 0 rows, but the bytes are still on MinIO.

**Step 2: Rewrite data files (Spark only)**

```python
# Run via spark-submit
spark.sql("""
    CALL iceberg.system.rewrite_data_files(
      table => 'analytics.events',
      where => "tenant_id = 'acme'"
    )
""")
```

What this does: Spark reads the affected Parquet files, applies the delete markers in memory, and writes **new** Parquet files without Acme's rows. A new snapshot points at these new files. But **the old Parquet files still exist on MinIO** because the prior snapshot still references them.

**Step 3: Expire old snapshots (Spark only) — THIS IS WHERE THE BYTES GET DELETED**

```python
spark.sql("""
    CALL iceberg.system.expire_snapshots(
      table        => 'analytics.events',
      older_than   => now() - interval '0' seconds,
      retain_last  => 1
    )
""")
```

What this does: Iceberg walks its metadata, identifies Parquet data files that no snapshot references anymore, and **issues S3 DELETE calls against MinIO**. This is the moment Acme's bytes are physically removed from storage.

**Important warning:** `older_than => now()` and `retain_last => 1` is aggressive — only use this for GDPR deletions. It expires all old snapshots immediately, which prevents time-travel queries and can cause in-flight queries to fail with "file not found." For normal weekly maintenance, use `older_than => now() - interval '30' day` instead.

**Step 4: Remove orphan files (Spark only) — CATCH-ALL FOR FAILED WRITES**

```python
spark.sql("""
    CALL iceberg.system.remove_orphan_files(
      table       => 'analytics.events',
      older_than  => now() - interval '1' day
    )
""")
```

What this does: Scans MinIO for Parquet files that no snapshot currently references. These "orphan files" typically come from Spark ingestion jobs that crashed mid-write — the file got uploaded but the snapshot commit failed. If one of your ingestion jobs happened to be writing Acme's data at the moment it crashed, the orphan file on MinIO still contains their bytes. This step sweeps those up and deletes them.

Why this is essential: `expire_snapshots` only deletes files that old snapshots referenced. Orphan files were never in any snapshot, so `expire_snapshots` doesn't know they exist. A regulator will find them if you skip this step.

The `older_than => now() - interval '1' day` is a safety buffer that prevents the procedure from deleting files currently being written by in-flight Spark jobs. Never set it more aggressively than 1 day in production.

### Verification: how to prove the data is really gone

After running all 4 steps, verify at three levels:

**Query layer:**
```sql
SELECT COUNT(*) FROM iceberg.analytics.events WHERE tenant_id = 'acme';
-- Expected: 0
```

**Metadata layer** (most auditable for regulators):
```sql
-- Check no snapshots from before the deletion remain
SELECT snapshot_id, committed_at, operation
FROM iceberg.analytics."events$snapshots"
ORDER BY committed_at;
-- Expected: single row — the post-delete snapshot only

-- Check no data files reference the deleted tenant
SELECT file_path, record_count
FROM iceberg.analytics."events$files"
WHERE partition.tenant_id = 'acme';
-- Expected: 0 rows
```

The `$files` table is your strongest evidence for a regulator — it shows that Iceberg itself reports no data files containing Acme's tenant partition. You can paste this query output into a compliance ticket.

**Storage layer:**
```bash
mc ls --recursive minio/lakehouse/warehouse/analytics/events/
# Visually verify no Parquet files from before the deletion remain
```

### The GDPR audit checklist

Do not skip any step:

1. `DELETE FROM iceberg.analytics.events WHERE tenant_id = 'acme'` — succeeds.
2. `CALL iceberg.system.rewrite_data_files(table => 'analytics.events', where => "tenant_id = 'acme'")` — succeeds.
3. `CALL iceberg.system.expire_snapshots(table => 'analytics.events', older_than => now() - interval '0' seconds, retain_last => 1)` — succeeds.
4. `CALL iceberg.system.remove_orphan_files(table => 'analytics.events', older_than => now() - interval '1' day)` — succeeds.
5. Verify: `SELECT COUNT(*) FROM iceberg.analytics.events WHERE tenant_id = 'acme'` returns `0`.
6. Verify: `SELECT * FROM iceberg.analytics."events$files" WHERE partition.tenant_id = 'acme'` returns 0 rows.
7. Verify: `SELECT snapshot_id FROM iceberg.analytics."events$snapshots" ORDER BY committed_at` shows only the current post-delete snapshot.
8. **Repeat steps 1–7 for every Iceberg table** that holds the customer's data (events, orders, users, sessions, etc.).

If you sign off after only step 1 (the DELETE), orphan files and old snapshot references still hold the customer's bytes. You are not compliant.

### Important notes for your stack

- **Engine matters for steps 2–4:** `CALL iceberg.system.*` syntax is **Spark SQL only**. Do not paste these into Trino — they will fail. Submit them via `spark-submit` or a Spark SQL session. If your team only has Trino access, use the Trino equivalent: `ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '0s')` — but verify the exact syntax for your Trino version.
- **One table at a time:** The procedures work on one table per invocation. If the customer has data in `events`, `orders`, `users`, and `sessions`, run the 4-step sequence for each table separately.
- **Automate this as a Spark job:** Wire it into Airflow or a Kubernetes CronJob so you're not manually running SQL commands for each deletion. The job should accept `tenant_id` and the list of affected tables as parameters.
- **Your 30-day window:** Run the full sequence as soon as you receive the deletion request, not on day 29. Step 3 (expire_snapshots) with `retain_last => 1` kills time-travel immediately — do this on a maintenance window to avoid in-flight query failures.
