# Iter279 Q1 — Stale Iceberg Data: Trino Metadata Cache and How to Fix It

## Answer

Yes — Trino has an in-memory Iceberg metadata cache on the coordinator, and coordinator restart is the definitive proof that it is the cause.

### 1. The Cache Is Real — Coordinator Restart Proves It

Trino's coordinator maintains an **in-memory cache of Iceberg metadata files** (table metadata JSON, manifest lists, manifest files) enabled by default via `iceberg.metadata-cache.enabled=true`. When your Spark pipeline commits a new snapshot, it writes a new metadata.json to S3 and updates the HMS pointer. But Trino's coordinator still holds the old metadata files in memory until the TTL expires.

**The definitive tell**: restarting the coordinator clears the in-memory cache and immediately reveals fresh data. This is textbook evidence that the metadata cache is the cause of your 10-15 minute staleness window. Without this pattern, the root cause might be HMS latency or Spark commit timing — but a coordinator restart fixing it confirms the cache.

### 2. There Is NO SQL Flush for Iceberg

This is the critical difference: **`CALL iceberg.system.flush_metadata_cache()` does NOT exist.** The `flush_metadata_cache()` procedure is available for Hive, Delta Lake, and JDBC connectors (PostgreSQL/MySQL) — but the Iceberg connector does NOT register this procedure. Attempting to call it returns a "Procedure not registered" error.

### 3. The Control Properties

Add to `etc/catalog/iceberg.properties`:

| Property | Default | Purpose |
|---|---|---|
| `iceberg.metadata-cache.enabled` | `true` | Master on/off switch for the coordinator cache |
| `fs.memory-cache.ttl` | ~10-60 min (build-dependent) | How long cached metadata files stay in memory |
| `fs.memory-cache.max-size` | `128MB` | Total bytes cached |
| `fs.memory-cache.max-content-length` | — | Max size per individual cached file |

### 4. Remediation Options

**Option A — Lower the TTL (recommended for your 10-minute pipeline):**
```properties
# etc/catalog/iceberg.properties
iceberg.metadata-cache.enabled=true
fs.memory-cache.ttl=30s
fs.memory-cache.max-size=512MB
```
Reduces the staleness window from 10-15 minutes to 30 seconds. Cost: Trino re-fetches metadata files from S3/HMS more often during query planning — adds minor overhead but is typically negligible.

**Option B — Disable the cache entirely:**
```properties
iceberg.metadata-cache.enabled=false
```
Every query reads metadata fresh from S3. No staleness at all. Cost: highest planning overhead — every query pays full S3 metadata read cost. Use only when any staleness is unacceptable, or for Iceberg tables with very frequent external writes.

**Option C — Accept the default:** Correct only for read-heavy Iceberg tables written infrequently (daily/weekly batch). Not suitable for your 10-minute pipeline.

### 5. Verifying the Cache Is the Cause

Before applying a fix, confirm the cache is the culprit:
```sql
SELECT * FROM iceberg_catalog.your_schema.your_table$snapshots
ORDER BY committed_at DESC LIMIT 5;
```
If the most recent snapshot ID does not match what Spark just committed, Trino is serving cached metadata. If it matches, look elsewhere (HMS latency, Spark commit timing).

### 6. Apply the Fix

Restart the coordinator after editing the properties file — TTL changes require a coordinator restart to take effect. The file change alone is not picked up while Trino is running.

**The fix:** lower `fs.memory-cache.ttl` to `30s` or `60s`, restart the coordinator once (planned), and your pipeline will be visible within seconds of each Spark commit instead of 10-15 minutes later.
