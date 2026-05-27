# Iter 224 Q2 — Cross-Catalog CTAS: Snapshotting MySQL Invoices into Iceberg

## Answer

Yes — cross-catalog CTAS works in Trino. You can snapshot `billing_mysql.billing.invoices` into Iceberg with a single statement, and Trino handles the atomicity so you won't end up with a half-written table.

### The SQL

```sql
CREATE TABLE iceberg.lakehouse.invoices_snapshot
WITH (
  partitioning = ARRAY['day(invoice_date)'],
  format = 'PARQUET'
)
AS SELECT * FROM billing_mysql.billing.invoices;
```

### What Trino Does Under the Hood — Step by Step

**1. HMS registers the new table at query start (empty metadata)**
The Hive Metastore creates a row for `invoices_snapshot` before any data flows. It points to an in-progress location in MinIO. The table entry exists in HMS but is not yet visible to readers because the metadata pointer hasn't been finalized.

**2. Trino workers read rows from MySQL over JDBC**
The coordinator distributes the SELECT across Trino workers. Each worker opens a JDBC connection to the MySQL replica and streams rows back to Trino. The data flows through Trino's network — there is no direct MySQL-to-MinIO path.

**3. Workers write Parquet files to MinIO**
As rows arrive, Trino workers serialize them into Parquet format and upload data files to MinIO at the table's data directory. Each worker writes its own files in parallel. These are initially "orphaned" — no Iceberg metadata points to them yet.

**4. On success: atomic metadata commit makes the table visible**
When all workers finish writing, the coordinator creates a final Iceberg metadata file (`metadata.json`) that lists all data files and their statistics. It then atomically updates HMS with a pointer to this metadata. The moment HMS is updated, every new query against the table sees the complete snapshot. Readers either see the complete table or nothing — there is no window where partial data is visible.

**5. On failure: the write is rolled back, no partial data appears**
If Trino crashes, the MySQL connection drops, or the coordinator fails before the commit step, the final metadata file is never written. The partial Parquet files left in MinIO become **orphans** — unreferenced by any snapshot. HMS has the table entry but it points to no valid metadata.

### Failure Mode Cleanup

**If the CTAS fails:**
```sql
-- Drop the table to remove the HMS entry; orphaned MinIO files
-- will be cleaned up by routine orphan file cleanup
DROP TABLE iceberg.lakehouse.invoices_snapshot;
```

Or leave it — `CALL iceberg.system.remove_orphan_files(schema_name => 'lakehouse', table_name => 'invoices_snapshot', older_than => TIMESTAMP '2026-05-26 00:00:00')` during routine maintenance will sweep them.

**MySQL connection drop:** Kills the query mid-SELECT. No data reaches MinIO. Drop the table and retry.

**Trino coordinator crash mid-write:** Workers' writes are left dangling in MinIO as orphaned files. HMS table entry is broken. Drop the table and retry.

### Verifying the Data Landed

After a successful CTAS:

```sql
-- 1. Row count should match source
SELECT COUNT(*) FROM iceberg.lakehouse.invoices_snapshot;
-- Compare to: SELECT COUNT(*) FROM billing_mysql.billing.invoices;

-- 2. Inspect the table structure
SHOW CREATE TABLE iceberg.lakehouse.invoices_snapshot;

-- 3. Check partition layout (metadata-only scan, very fast)
SELECT * FROM iceberg.lakehouse."invoices_snapshot$partitions" LIMIT 10;

-- 4. Spot-check rows
SELECT * FROM iceberg.lakehouse.invoices_snapshot LIMIT 5;
```

### Partitioning Recommendation

Always add a partition spec to make the Iceberg table queryable efficiently:

```sql
WITH (
  partitioning = ARRAY['day(invoice_date)'],
  format = 'PARQUET'
)
```

For a multi-tenant SaaS invoicing table, consider two levels:

```sql
WITH (
  partitioning = ARRAY['day(invoice_date)', 'bucket(tenant_id, 16)'],
  format = 'PARQUET'
)
```

This lets per-tenant dashboards prune to one tenant × time range, and company-wide reports prune by date range alone.

### Practical Considerations

**Use a MySQL read replica, not the primary.** The CTAS holds the JDBC connection open for the entire duration — potentially hours for a large table. Running against your live primary adds replication lag and can block other reads.

**CTAS holds the JDBC connection open for the full duration.** There is no batching or checkpoint within the CTAS. For a 10 GB table, this can run for 1–10 hours depending on network speed. Monitor `SHOW PROCESSLIST` on the MySQL replica to ensure the connection doesn't hit a timeout.

**CTAS is NOT idempotent.** Re-running the same CTAS creates a duplicate table (or fails if the target exists). This is a one-time "snapshot at this moment" operation.

### Incremental Updates After the Snapshot

Once the snapshot is in place, load new rows using `INSERT INTO`:

```sql
-- Load only invoices added since the snapshot (simple watermark)
INSERT INTO iceberg.lakehouse.invoices_snapshot
SELECT * FROM billing_mysql.billing.invoices
WHERE invoice_date >= CURRENT_DATE - INTERVAL '1' DAY;
```

Or a robust watermark pattern:

```sql
WITH max_loaded AS (
  SELECT MAX(invoice_date) AS last_date
  FROM iceberg.lakehouse.invoices_snapshot
)
INSERT INTO iceberg.lakehouse.invoices_snapshot
SELECT *
FROM billing_mysql.billing.invoices
WHERE invoice_date > (SELECT last_date FROM max_loaded)
  AND invoice_date <= CURRENT_DATE;
```

This ensures you never miss rows and never duplicate them, even if the load is re-run.
