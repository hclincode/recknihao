# Iter81 Q1 — Answer

**Question**: Billing query: `SELECT tenant_id, COUNT(*) FROM events WHERE event_time >= '2026-05-01' GROUP BY tenant_id`. Will it work? Is it slow? Does partition choice matter? Does Trino have to scan all tenants' rows?

---

## Answer

The query will work correctly — the results will be right. Whether it's fast depends almost entirely on your partition design.

### Why partition design matters here

Iceberg uses **hidden partitioning**: your `WHERE event_time >= '2026-05-01'` filter automatically prunes to only May's files. You don't need to write `AND day(event_time) = '2026-05-01'`; Trino translates the timestamp range into the correct partition boundaries.

But your query has no tenant filter — it scans all tenants. So partition pruning cannot skip any tenant's files. Trino will open every file in May's partitions regardless of the partition design. The partition choice affects *how efficiently* those files are laid out, not *which* files get read.

### Date-only partitioning (`ARRAY['day(event_time)']`)

Trino prunes to May's day-partitions (31 files per day at most). Within each file, tenant data is scattered — row groups for different tenants are interleaved. Trino reads every row group in every May file, counts by tenant, and returns the result.

This works and is reasonably fast for 50M rows/month if your files are properly compacted (256 MB each). Expect seconds on a well-tuned cluster.

### Date + tenant partitioning (`ARRAY['day(event_time)', 'tenant_id']`)

The recommended layout for B2B SaaS. Within each day-partition, each tenant's rows live in separate files. For your billing query:
- Trino still opens all of May's files (no tenant pruning since you want all tenants)
- But file reads are more cache-efficient because each file contains only one tenant's data — sequential reads dominate over random access

The bigger payoff: per-tenant follow-up queries (`WHERE tenant_id = 'acme'`) become fast because Trino can skip every file that doesn't belong to that tenant. For billing workflows where you then drill into a specific customer's invoice details, this is the partition layout you want.

### Does Trino do anything "smarter" to avoid scanning all rows?

For a simple `COUNT(*)`, Trino can use Parquet column statistics (row count per row group) to skip reading actual row data — it just reads the footer metadata. This means a well-compacted table with good Parquet statistics can answer your billing query without reading any actual event payload data, just the row counts from each file's metadata. This is fast even for large tables.

For `COUNT(DISTINCT user_id)` or more complex aggregations, Trino must read the actual column values and the optimization doesn't apply.

### Bottom line

| Partition layout | Billing query speed | Per-tenant query speed |
|---|---|---|
| `day(event_time)` only | Good (prunes to month, reads all rows) | Slow (full month scan per tenant) |
| `day(event_time), tenant_id` | Good (same scan, better file locality) | Fast (prunes to tenant's files) |
| `tenant_id` only | Slow (no date pruning — scans full table) | Fast per-tenant, slow cross-tenant |

**Recommended**: `ARRAY['day(event_time)', 'tenant_id']` — the billing query runs fast (month pruning), per-tenant dashboard queries run fast (tenant pruning), and cross-tenant internal analytics also work efficiently.

### If the billing query is still slow

Run `EXPLAIN ANALYZE` on it and check the file count in the table scan operator. If you're opening thousands of files, compaction likely hasn't run recently — many tiny files inflate I/O overhead. Schedule `ALTER TABLE events EXECUTE optimize` (Trino) or `CALL iceberg.system.rewrite_data_files(...)` (Spark) nightly to keep file count manageable.
