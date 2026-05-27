# Iter80 Q1 — Answer

**Question**: One specific tenant's dashboard is consistently slow while others are fine. We partition by tenant_id. Where do we start diagnosing this?

---

## Answer

Partitioning by `tenant_id` gives you physical data isolation — Trino skips other tenants' files. But it doesn't guarantee equal query speed. One tenant being slower than others usually traces to one of four causes. Here's how to find which one in about 10 minutes.

### Step 1: Check for concurrency — is this really a one-tenant problem?

Open the Trino UI (`http://trino-coordinator:8080/ui/queries`) and look at whether queries from this tenant are queued or actively running. If 20 of their dashboard panels all refresh at 9:00 AM, they're competing with each other for cluster resources — not a data problem, a concurrency problem.

```sql
SELECT query_id, user, state, resource_group_id
FROM system.runtime.queries
WHERE user = '<their service account>'
ORDER BY created DESC
LIMIT 20;
```

If you see 10+ `RUNNING` queries simultaneously and no resource group limits, their refresh schedule is the culprit. Fix: stagger dashboard refresh times, or add a resource group entry capping their concurrency to 5 simultaneous queries.

### Step 2: Run EXPLAIN ANALYZE on their slowest query

```sql
EXPLAIN ANALYZE
SELECT <their representative slow query>
```

The single most important number in the output is **Files** — how many Parquet files Trino opened:

| Files count | What it likely means |
|---|---|
| ~1–5 per day in range | Partition pruning working correctly |
| 500+ for a 30-day range | Missing partition filter or broken pruning |
| 1,000+ total | Small-files accumulation (compaction needed) |

If their files count is 100× what you'd expect, the query is either scanning everything or the partition has fragmented into tiny files.

### Step 3: Check if this tenant just has much more data (partition skew)

```sql
SELECT
  tenant_id,
  COUNT(*)                       AS row_count,
  COUNT(DISTINCT DATE(event_ts)) AS days_of_data
FROM iceberg.analytics.events
GROUP BY tenant_id
ORDER BY row_count DESC;
```

If this tenant has 50× more rows than others, their queries legitimately scan more data. That's **partition skew** — one partition is disproportionately large, so queries against it do more work regardless of how well Trino prunes.

Fix options: a nightly pre-aggregated rollup table for this tenant's heavy queries, or moving them to a dedicated table if they're large enough to warrant it.

### Step 4: Check compaction status — small files problem

If EXPLAIN ANALYZE shows an unexpectedly high file count, check how many files the table has accumulated:

```sql
SELECT
  snapshot_id,
  added_data_files_count,
  total_data_files_count
FROM iceberg.analytics."events$snapshots"
ORDER BY committed_at DESC
LIMIT 5;
```

If `total_data_files_count` is in the tens of thousands, compaction hasn't kept up. Every file takes 10–50 ms to open — 10,000 files × 30 ms = 5 minutes of overhead before reading any actual data.

This affects all tenants, but queries that touch uncompacted recent data (this tenant's range) suffer more than queries against older, already-compacted partitions.

### Step 5: Look for a query change

Compare their current slow query to a version from two weeks ago. Did someone:
- Remove a `WHERE event_date BETWEEN ...` filter on the partition column? (Now it's a full scan.)
- Expand the date range from 7 days to 90 days?
- Add a join that wasn't there before?

Run EXPLAIN ANALYZE on both. If `Input rows` jumped 100×, the query changed, not the data.

### Step 6: Confirm resource group assignment

If you've set up per-tenant resource groups, verify their queries are actually landing in the right group:

```sql
SELECT resource_group_id, COUNT(*) 
FROM system.runtime.queries 
WHERE user = '<their service account>'
  AND created > NOW() - INTERVAL '1' HOUR
GROUP BY resource_group_id;
```

If they show `global` instead of `global.tenant_acme`, the selector isn't matching their JWT principal — their queries are running uncapped and potentially competing with everyone else's.

### Quick diagnosis flow

1. **Trino UI** — 10+ concurrent queries? → concurrency/resource groups problem
2. **EXPLAIN ANALYZE** → high file count? → small files (run compaction) or missing partition filter
3. **Row count query** → 50× more rows than others? → partition skew, consider rollup
4. **Query diff** → date range or filter changed? → fix the query

Most one-tenant slowdowns trace to #1 (no resource group limits + dashboard refresh storm) or #2 (compaction hasn't run). Start there.
