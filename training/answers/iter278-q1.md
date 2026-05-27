# Iter278 Q1 — Stale Iceberg Data After Spark Writes

## Answer

Based on your production environment (Spark + Iceberg 1.5.2 + Trino 467 + Hive Metastore), the stale-data problem after Spark writes is not caused by a Trino metadata cache for Iceberg. Here's what's actually happening and how to fix it.

### 1. Why You're Seeing Stale Data

**The key point:** Trino's Iceberg connector does NOT maintain a metadata pointer cache. Every query contacts Hive Metastore (HMS) to fetch the current `metadata.json` location. This is by design — caching the pointer would miss concurrent Spark commits.

So if Trino is returning old data for 10-15 minutes after Spark finishes, the problem is outside Trino's control:

**Most likely cause 1 — HMS latency**: After Spark commits, the HMS backing database (Postgres/MySQL) might not propagate the updated pointer immediately. If your HMS is slow or under load, Trino's requests may return the old pointer for several minutes.

**Most likely cause 2 — Spark commit timing**: The Spark job may report success before the metadata.json file is fully written to MinIO or before the HMS pointer is atomically updated. Iceberg 1.5.2 commits are atomic, but ensure your job waits for the commit rather than fire-and-forget.

### 2. The Command to Force Metadata Refresh

For Iceberg in Trino, there is no cache to flush because there is no Iceberg metadata pointer cache in the coordinator. The `flush_metadata_cache()` procedure exists for other connectors (PostgreSQL, MySQL, Hive, Delta Lake) that DO cache schema metadata.

For the connectors that do have it, the syntax is:
```sql
CALL catalog.system.flush_metadata_cache();
-- or for a specific table:
CALL catalog.system.flush_metadata_cache(
  schema_name => 'my_schema',
  table_name => 'my_table'
);
```

**Important scope note:** When this procedure is called, it only flushes the cache on the **coordinator node** where it executes. It is NOT cluster-wide — worker nodes have their own in-flight plan caches, but those are per-query and expire naturally.

### 3. The metadata.cache-ttl Property

The `metadata.cache-ttl` configuration exists for **federated connector catalogs** (PostgreSQL, MySQL) that cache schema definitions — not for Iceberg table metadata. If you're seeing stale data on your Iceberg tables, this property is not the lever to turn.

### 4. The CREATE OR REPLACE VIEW Workaround

For Postgres-federated views using `SELECT *`: when Postgres adds a column, a Trino view created with `SELECT *` expands the column list once at creation time and freezes it. After a Postgres schema change, recreating the view with `CREATE OR REPLACE VIEW` forces Trino to re-derive the column list. This is specific to Postgres federation, not Iceberg.

### 5. What to Actually Do

**Step 1 — Measure HMS round-trip time.** Look at your Trino query logs for the metadata fetch phase duration after Spark writes. If it's consistently elevated, HMS is the bottleneck.

**Step 2 — Verify Spark commit atomicity.** Confirm your Spark job is waiting for the Iceberg table commit before the driver exits. Asynchronous commit patterns can produce exactly the 10-15 minute delay you're seeing.

**Step 3 — Check MinIO replication lag.** If your MinIO cluster uses erasure coding or multi-site replication, the new `metadata.json` file may not be readable from all endpoints immediately after Spark writes it.

**Step 4 — HMS health check.** Look at the backing Postgres/MySQL database for your HMS. If it's under write pressure from Spark's commits and simultaneous read requests from Trino, the old pointer may be served from a read replica with replication lag.

### Summary

There is no Trino-side cache to flush for Iceberg and no TTL to tune. The staleness window is in Spark's commit path or HMS's response latency — investigate those before changing Trino configuration. Restarting the Trino coordinator should not be necessary and is not the correct fix.
