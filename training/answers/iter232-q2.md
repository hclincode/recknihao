# Iter 232 Q2 — Cross-Catalog Query Startup Delay (Iceberg + MySQL)

## Answer

You're experiencing a **query planning delay**, not an execution delay. The delay comes from three separate sources that all happen during the planning phase — before the progress bar starts.

### Source 1: Hive Metastore (HMS) Metadata Lookup

Every time Trino plans a query against Iceberg tables, the Iceberg connector must contact Hive Metastore to resolve the current metadata location (the pointer to the latest `metadata.json` in MinIO). This is a Thrift RPC call to HMS. For each Iceberg table in the query, there's a separate HMS roundtrip.

Under normal conditions, a single HMS call is <10ms. But latency accumulates when:
- Multiple Iceberg tables are in the query
- HMS has a slow Postgres backend
- Network latency exists between Trino and HMS

**Why pure-Iceberg queries start fast**: they hit only Iceberg → HMS. Once resolved, everything happens locally in MinIO.

**Why adding a MySQL JOIN is slow**: you now have multiple overlapping planning sources.

### Source 2: MySQL Metadata Discovery and Statistics Fetch

When Trino plans the join, it queries MySQL's `information_schema` to discover column schemas and table row counts for cost-based optimization. This is a separate JDBC connection that blocks planning until MySQL responds. On-prem MySQL replicas with any network latency or query load can add 5-10 seconds here.

If `metadata.cache-ttl` is set on your MySQL catalog, the cache lookup happens per-table and can serialize these calls rather than parallelize them.

### Source 3: Dynamic Filtering Wait Timeout

By default, Trino waits up to **20 seconds** for the MySQL build side of a join to complete before proceeding with Iceberg scan. During query planning and early execution, this wait can appear as a startup pause when the MySQL read takes time to return join keys.

Note: for Iceberg connectors, the default wait is only **1 second** — much shorter. The 20s default for JDBC (MySQL) connectors reflects that JDBC reads are slower and less predictable.

---

## Concrete Configuration Fixes

### Fix 1: Reduce MySQL Metadata Cache TTL

In your MySQL catalog properties (`/etc/trino/catalog/<mysql_catalog>.properties`):

```properties
# Reduce from typical 60s-300s to 5s
metadata.cache-ttl=5s
metadata.cache-missing=true
```

This makes Trino refresh MySQL schema metadata more aggressively. The trade-off: slightly higher `information_schema` query load on the MySQL replica.

### Fix 2: Ensure HMS is HA and Latency-Optimized

Trino should point at multiple HMS pods, not a single one. In `/etc/trino/catalog/iceberg.properties`:

```properties
hive.metastore.uri=thrift://hms-0.hive-metastore:9083,thrift://hms-1.hive-metastore:9083,thrift://hms-2.hive-metastore:9083
```

Or use a Kubernetes Service:
```properties
hive.metastore.uri=thrift://hive-metastore:9083
```

Ensure Trino pods and HMS pods are on the same cluster network segment — latency should be <1ms.

### Fix 3: Tune Dynamic Filtering Wait Timeout for Iceberg Side

Increase the wait timeout in your Iceberg catalog to give MySQL more time to return join keys before Iceberg gives up and scans everything:

```properties
# In /etc/trino/catalog/iceberg.properties:
dynamic-filtering.wait-timeout=15s
```

The default of **1 second** (Iceberg connector default) is too short for on-prem MySQL replicas. Increasing to 15s means Iceberg waits longer for MySQL to finish and return join keys — then the Iceberg scan can prune files that don't match, making total execution faster.

### Fix 4: Add a Numeric or Date Predicate Alongside VARCHAR Filters

If your join or WHERE clause involves VARCHAR columns (which do NOT push down to MySQL), add a complementary numeric or date filter to reduce rows MySQL ships over JDBC:

```sql
-- Before (slow — MySQL ships entire table)
SELECT * FROM iceberg.analytics.events e
JOIN mysql_catalog.app.users u ON e.user_id = u.id
WHERE u.status = 'active';

-- After (faster — MySQL applies date range first, ships smaller result)
SELECT * FROM iceberg.analytics.events e
JOIN mysql_catalog.app.users u ON e.user_id = u.id
WHERE u.updated_at >= DATE '2026-05-01'  -- MySQL can push this (date range)
  AND u.status = 'active';               -- Trino filters in memory on smaller set
```

---

## Summary: What's Causing Your 10-15 Second Delay

| Source | Typical Duration | Fix |
|--------|-----------------|-----|
| HMS metadata lookup (1-3 Iceberg tables) | 2-5 seconds | Ensure HMS is HA, latency-optimized |
| MySQL `information_schema` fetch + statistics | 5-10 seconds | Reduce `metadata.cache-ttl` to 5s |
| Dynamic filtering wait (Iceberg waits for MySQL build side) | 1-5 seconds | Increase Iceberg `dynamic-filtering.wait-timeout` to 15s |

Fixes 1 and 3 together typically cut the startup delay from 10-15 seconds to 2-3 seconds.

## Files to Check

- `/etc/trino/catalog/iceberg.properties` — check `hive.metastore.uri` (should list multiple HMS endpoints) and add `dynamic-filtering.wait-timeout=15s`
- `/etc/trino/catalog/<mysql_catalog>.properties` — check `metadata.cache-ttl` (reduce to 5s if schema is stable)
