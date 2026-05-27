# Iter 152 Q1 — Reading Trino EXPLAIN ANALYZE to Diagnose Query Slowdown

## Answer

EXPLAIN ANALYZE is exactly the right tool for this. The output is dense but most of it is not relevant to your specific problem. Here is how to cut through it.

### Start with one number: `Files:`

Look for the `Files:` line in your EXPLAIN ANALYZE output. This is the single most important number for an Iceberg query performance regression.

For your query — filtering by `tenant_id` and a 30-day date range — you should see roughly 30 files if partition pruning is working correctly (about one file per day per partition). If you see 4,000+ files, partition pruning broke or the table is unpartitioned.

**This is the most common cause of an overnight 3-second → 45-second regression with no code changes.** Trino opens every file to read its metadata footer. Opening 30 files takes milliseconds; opening 5,000 files takes minutes just for metadata overhead, before any data is read.

### Second check: `Input: rows` and `Input: bytes`

Look at the `Input:` line showing bytes scanned. Compare to what you expect for a 30-day range on your events table. If it jumped from 500 MB to 20 GB overnight, either:
- The table grew significantly
- A filter that was working is now broken
- Partition pruning stopped working for the `tenant_id` or `event_date` filter

### Third check: `Wall time` vs `CPU time`

Look at the timing breakdown in the output:

| Pattern | What it means | Fix direction |
|---|---|---|
| Wall time: 45s, CPU time: 5s | I/O-bound — waiting for data from MinIO, too many files to open | Files count, compaction, partition pruning |
| Wall time: 45s, CPU time: 40s | Compute-bound — aggregation or join is doing real work | Query logic, intermediate result size |

For `COUNT(DISTINCT user_id)` filtered to one tenant and 30 days, this should be mostly I/O-bound if partition pruning is working. Wall time much greater than CPU time points to too many files or excessive data volume.

### Run the diagnosis now

```sql
EXPLAIN ANALYZE
SELECT COUNT(DISTINCT user_id)
FROM iceberg.analytics.events
WHERE tenant_id = '<your_tenant_id>'
  AND event_date >= CURRENT_DATE - INTERVAL '30' DAY;
```

Record these numbers from the output:
1. `Files:` count
2. `Input: rows` and `Input: bytes`
3. `Wall time` and `CPU time`

### Verify partition pruning is active

Check that your table has partition columns that match your WHERE clause:

```sql
SHOW CREATE TABLE iceberg.analytics.events;
```

Look for a `partitioning = ARRAY[...]` clause. If you see `day(event_date)` and `tenant_id` there, partition pruning should be working when your WHERE clause filters on those columns. If there is no `partitioning` clause, the table is unpartitioned and every query scans the entire table.

**Common mismatch**: if the table is partitioned on `day(event_date)` but your WHERE clause filters on `DATE(event_timestamp)` instead, Trino cannot push the filter down to partition elimination and will scan everything.

### If Files count is much higher than expected — common causes

- Someone changed the table partitioning recently (partition evolution drops pruning on old files until they are rewritten)
- The nightly compaction job stopped running — check Kubernetes CronJob logs for the `rewrite_data_files` job
- A recent ingestion change wrote files without partition metadata
- The `tenant_id` filter is not pushed down because it contains a function or cast

### Check compaction job status

```sql
-- Check if compaction ran recently
SELECT snapshot_id, committed_at, operation, summary
FROM iceberg.analytics.events$snapshots
WHERE operation = 'replace'  -- compaction shows as 'replace'
ORDER BY committed_at DESC
LIMIT 5;
```

If you don't see any `replace` operations in the last 24 hours but your nightly compaction is scheduled, the job is failing silently. File count grows with each streaming micro-batch and queries degrade over time.

### Summary: diagnostic sequence

1. Run `EXPLAIN ANALYZE` — record `Files:`, `Input: bytes`, `Wall time`
2. Run `SHOW CREATE TABLE` — confirm partition columns match your WHERE clause filters
3. Check `$snapshots` — confirm compaction ran recently (operation = 'replace')
4. If files count is high and compaction ran: check partition pruning filter column match
5. If compaction did not run: fix the CronJob and run ad-hoc `ALTER TABLE ... EXECUTE optimize`
