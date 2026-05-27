# Iter98 Q1 — Answer

**Question**: We're running a multi-tenant SaaS product and our customers have started asking us to show them a breakdown of how much storage their data is using in our analytics system. We moved event data into some kind of table format on S3 recently and I know there are metadata files that track things like file counts and sizes. Is there a way to query that metadata directly to show each tenant their own storage footprint — like a per-tenant storage usage report — without having to scan all the actual data? And is there any realistic way to alert or automatically stop ingestion if a particular tenant's data blows past a size threshold we set?

---

## Answer

## Part 1: Per-tenant storage without scanning data

Iceberg's `$files` metadata table exposes file counts and sizes at the partition level — you can break down storage by tenant without reading a single row of actual data.

```sql
-- Per-tenant storage and file count (runs in milliseconds — metadata only)
SELECT
  partition.tenant_id,
  COUNT(*)                                                    AS file_count,
  SUM(record_count)                                           AS total_rows,
  ROUND(SUM(file_size_in_bytes) / 1024.0 / 1024.0 / 1024.0, 2) AS total_gb
FROM iceberg.analytics."events$files"
GROUP BY partition.tenant_id
ORDER BY total_gb DESC;
```

This only touches Iceberg's metadata layer — the `$files` table. No Parquet files in MinIO are opened. Results in milliseconds even on a table with billions of rows.

**Key `$files` columns:**
- `partition` — struct containing your partition keys (e.g., `tenant_id`, `day(event_ts)`)
- `file_size_in_bytes` — size of this single Parquet file
- `record_count` — rows in this file
- `file_path` — MinIO location (useful for debugging)

Extended query with compression check:

```sql
SELECT
  partition.tenant_id,
  COUNT(*)                                                       AS file_count,
  SUM(record_count)                                             AS total_rows,
  ROUND(SUM(file_size_in_bytes) / 1024.0 / 1024.0 / 1024.0, 2) AS total_gb,
  ROUND(SUM(file_size_in_bytes) * 1.0 / NULLIF(SUM(record_count), 0), 2) AS bytes_per_row
FROM iceberg.analytics."events$files"
GROUP BY partition.tenant_id
ORDER BY total_gb DESC;
```

The `bytes_per_row` column is your compression-ratio check — if one tenant shows 5 bytes/row vs 0.5 bytes/row for others, they either have high-cardinality data (UUIDs, raw JSON) or uncompacted small files.

**Security note:** The `$files` table exposes your entire tenant roster and storage distribution. Tenant service accounts must NOT be able to query metadata tables — this is exactly the cross-tenant metadata leak described in the multi-tenant isolation resources. OPA must deny queries where the table name contains `$` for all tenant principals. Run these queries only as an admin/internal service account.

## Part 2: Alerting and capping per-tenant storage

Iceberg has no built-in per-tenant quota. You add it with a lightweight alerting layer:

### Step 1: Store daily storage snapshots

```sql
-- Run as a nightly k8s CronJob
INSERT INTO analytics.tenant_storage_audit
SELECT
  CURRENT_TIMESTAMP   AS captured_at,
  partition.tenant_id AS tenant_id,
  COUNT(*)            AS file_count,
  SUM(record_count)   AS total_rows,
  SUM(file_size_in_bytes) AS total_bytes
FROM iceberg.analytics."events$files"
GROUP BY partition.tenant_id;
```

This small summary table is your single source of truth. It builds a historical trend so you can see which tenants are growing fastest.

### Step 2: Alert query

```sql
-- Tenants exceeding 50 GB quota
SELECT tenant_id, ROUND(total_bytes / 1024.0^3, 2) AS total_gb
FROM analytics.tenant_storage_audit
WHERE DATE(captured_at) = CURRENT_DATE
  AND total_bytes > 50 * 1024 * 1024 * 1024
ORDER BY total_bytes DESC;
```

Run this query in your monitoring system (or push results to your alerting channel) after the nightly snapshot.

### Step 3: Gate ingestion in Spark

Before Spark writes new data for a tenant, check the summary table:

```python
def should_ingest_tenant(spark, tenant_id, quota_bytes):
    result = spark.sql(f"""
        SELECT total_bytes FROM analytics.tenant_storage_audit
        WHERE tenant_id = '{tenant_id}'
        ORDER BY captured_at DESC LIMIT 1
    """).collect()

    current_bytes = result[0][0] if result else 0

    if current_bytes > quota_bytes:
        raise Exception(
            f"Tenant {tenant_id} exceeded quota "
            f"({current_bytes} bytes > {quota_bytes} bytes). Ingestion stopped."
        )
    return True

# In your main ingestion job
for tenant_id in tenants:
    if should_ingest_tenant(spark, tenant_id, quota_bytes=50 * 1024**3):
        # ingest this tenant's data
        df.writeTo(f"iceberg.analytics.events").append()
```

This is a soft cap checked at job start — not per-row. If a job starts under quota and writes enough data to cross it during the run, the in-flight commit completes (Iceberg is ACID — partial writes don't land). For practical SaaS use, a nightly check + alert + ops response is sufficient.

### Step 4: Customer-facing view

Expose the summary table to each tenant via a Trino view scoped to their tenant_id:

```sql
CREATE VIEW tenant_acme.storage_usage AS
  SELECT captured_at, file_count, total_rows, total_bytes
  FROM analytics.tenant_storage_audit
  WHERE tenant_id = 'acme'
  ORDER BY captured_at DESC;
```

Customers can query their own storage history without seeing other tenants.

## Why metadata queries are safe to run frequently

The `$files` query runs in milliseconds regardless of table size — it only reads Iceberg's metadata layer (manifests and manifest lists), never the Parquet data files. You can run it multiple times per day with no cost or performance impact.
