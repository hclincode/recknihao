# Iter117 Q2 — Answer

**Question**: One of our larger enterprise customers signed a contract that includes a GDPR data portability clause — they want to be able to pull all their historical data if they ever leave us, and also have us delete everything we have on them within 30 days of termination. All their data lives in our shared Iceberg tables partitioned by `tenant_id` and event date, and they have about 3 years of data across hundreds of millions of rows. I understand deleting rows from Iceberg is possible, but what I'm confused about is the export side — how do I give them a complete, clean export of just their data (in some format they can actually use, like CSV or Parquet) without melting our query engine by scanning 3 years of partitions, and how do I confirm to them that after deletion, their data is genuinely gone from storage and not just logically hidden?

---

## Answer

You have two separate problems: (1) export without overwhelming the cluster, and (2) physical deletion that satisfies GDPR. Both have well-tested patterns on Trino + Iceberg.

### Part A: Export Without Melting the Query Engine

**Core pattern: write to an isolated export table directly in MinIO using Trino `INSERT INTO ... SELECT`.** This bypasses your application layer entirely — no timeouts, no memory pressure on your app servers.

**Step 1: Create an isolated export table**

```sql
-- Trino — creates a new Iceberg table at a dedicated MinIO prefix
CREATE TABLE iceberg.exports.acme_export_20260525 (
  LIKE iceberg.analytics.events INCLUDING PROPERTIES
)
WITH (
  location = 's3a://lakehouse/exports/acme/20260525/',
  format   = 'PARQUET'
);
```

**Step 2: Write the tenant's data with partition pruning**

```sql
SET SESSION query_max_execution_time = '4h';  -- for a large tenant's 3-year data

INSERT INTO iceberg.exports.acme_export_20260525
SELECT * FROM iceberg.analytics.events WHERE tenant_id = 'acme';
```

Why this doesn't melt the cluster:
- **Partition pruning**: if `analytics.events` is partitioned by `tenant_id` (or `bucket(tenant_id, N)`), Trino reads only Acme's physical Parquet files — not the entire 3-year table.
- **Distributed write**: Trino workers write Parquet files directly to MinIO in parallel. No row data passes through your application.
- **Your app just submits the SQL** and polls for completion via the Trino REST API (`POST /v1/statement`).

**Step 3: Hand off the data in a usable format**

Option A — Flat Parquet (easiest for most customers):
```bash
# Copy the exported Parquet files to a customer-accessible location
mc cp --recursive minio/lakehouse/exports/acme/20260525/data/ ./acme_export_parquet/
```
Every modern tool (pandas, DuckDB, Excel, Tableau, Python `pyarrow`, Spark) reads Parquet natively.

Option B — CSV (if they explicitly require it):
```python
# Spark: convert to gzipped CSV for universal compatibility
df = spark.sql("""
    SELECT * FROM iceberg.exports.acme_export_20260525
""")
df.coalesce(10).write.option("compression", "gzip").mode("overwrite") \
  .csv("s3a://lakehouse/exports/acme/csv/")
# Then hand off the gzip files
```

**Step 4: Clean up after delivery**

```sql
-- Drops the table AND deletes the underlying MinIO files
DROP TABLE iceberg.exports.acme_export_20260525;
```

---

### Part B: Physical Deletion (GDPR Compliance)

A simple `DELETE` is not enough for GDPR. Iceberg's MVCC means the original Parquet bytes remain on MinIO, referenced by older snapshots. You need the full 4-step physical removal sequence:

**Step 1: DELETE the rows**

```sql
-- In Trino: logical deletion, all tables
DELETE FROM iceberg.analytics.events        WHERE tenant_id = 'acme';
DELETE FROM iceberg.analytics.sessions      WHERE tenant_id = 'acme';
DELETE FROM iceberg.analytics.user_profiles WHERE tenant_id = 'acme';
DELETE FROM iceberg.analytics.audit_logs    WHERE tenant_id = 'acme';
-- ... all tables holding tenant data
```

After this: queries return 0 rows. Bytes still on MinIO.

**Step 2: Rewrite data files to produce new clean Parquet without the tenant**

```python
# Spark — NOT Trino EXECUTE optimize (Trino does not apply position delete files)
spark.sql("""
    CALL iceberg.system.rewrite_data_files(
        table => 'analytics.events',
        where => "tenant_id = 'acme'"
    )
""")
# Repeat for all tables
```

New Parquet files written with no trace of Acme's rows. Old files still on MinIO but now unreferenced by the latest snapshot.

**Step 3: Expire old snapshots (this is the step that physically deletes bytes)**

```python
# Spark — NOT Trino (Trino enforces a 7-day minimum retention floor; Spark has no floor)
spark.sql("""
    CALL iceberg.system.expire_snapshots(
        table        => 'analytics.events',
        older_than   => current_timestamp(),
        retain_last  => 1
    )
""")
# Repeat for all tables
```

Iceberg removes old snapshot metadata and triggers MinIO DELETE calls on all unreferenced Parquet files, delete files, Avro manifests, and manifest list files. After this step, no trace of the old snapshots remains on storage.

**Before running Step 3**, check for retention table properties that could silently block it:

```sql
SHOW CREATE TABLE iceberg.analytics.events;
-- Look for: 'history.expire.min-snapshots-to-keep' or 'history.expire.max-snapshot-age-ms'
-- If present, unset temporarily:
ALTER TABLE iceberg.analytics.events UNSET PROPERTIES ('history.expire.min-snapshots-to-keep');
-- Run step 3, then restore
```

**Step 4: Sweep MinIO for orphan files**

```python
spark.sql("""
    CALL iceberg.system.remove_orphan_files(
        table      => 'analytics.events',
        older_than => current_timestamp() - INTERVAL '1' DAY
    )
""")
# Repeat for all tables
```

---

### Proving Deletion to the Customer (Audit Checklist)

**Query layer:**
```sql
SELECT COUNT(*) FROM iceberg.analytics.events WHERE tenant_id = 'acme';
-- Expected: 0
```

**Metadata layer:**
```sql
-- Only one snapshot should remain (the post-purge state)
SELECT snapshot_id, committed_at, operation
FROM iceberg.analytics."events$snapshots";
-- Expected: 1 row

-- No files reference the tenant's partition
SELECT file_path, record_count
FROM iceberg.analytics."events$files"
WHERE partition.tenant_id = 'acme';
-- Expected: 0 rows
```

**Storage layer:**
```bash
# MinIO: list Acme's partition directory — should be empty
mc ls --recursive minio/lakehouse/warehouse/analytics/events/tenant_id=acme/
```

### Don't Forget the Export Table

The export table you created in Part A has its own MinIO files that also contain Acme's data. After the customer confirms receipt:

```sql
DROP TABLE iceberg.exports.acme_export_20260525;
```

This triggers MinIO deletion of the export files. Run `remove_orphan_files` on the exports namespace if needed.

### Timeline for 30-Day Deadline

| Day | Action |
|---|---|
| Day 1 | Run Steps 1–2 (DELETE + rewrite). Export delivered to customer. |
| Day 2–7 | Customer verifies export. Bytes logically deleted but old snapshots may still exist. |
| Day 7–8 | Run Step 3 (expire_snapshots via Spark). Old bytes deleted from MinIO. |
| Day 8 | Run Step 4 (remove_orphan_files). Run audit checklist. Sign off. |
| Day 28 | Optional: re-verify audit checklist. Confirm to customer in writing. |

For urgency (legal/contract requirement), Spark's `expire_snapshots` with no minimum retention can collapse Steps 3–4 to Day 1–2.
