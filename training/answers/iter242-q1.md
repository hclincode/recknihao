# Iter242 Q1 — Dynamic Filter Compaction Threshold (domain-compaction-threshold)

## What's Happening

You are seeing the effects of **domain-compaction-threshold**, a Trino setting that automatically converts a large IN-list filter into a BETWEEN range filter before it reaches PostgreSQL. Here's the mechanics:

When Trino's dynamic filtering derives a filter from your PostgreSQL customer subquery, it starts as an exact IN-list — e.g., `WHERE customer_id IN (1, 5, 17, 42, ...)`. But when the number of distinct values exceeds the **`domain-compaction-threshold` (default: 256)**, the PostgreSQL connector compacts it to a min/max range like `WHERE customer_id BETWEEN 1 AND 100` before sending the SQL to PostgreSQL. Your 500-customer segment exceeds this threshold, so the filter degrades.

This matters very differently on the two sides:

**On the Iceberg side:** The dynamic filter pushes to Iceberg's file pruning. When Trino receives a BETWEEN range instead of an IN-list, Iceberg can still skip Parquet files whose min/max statistics fall outside the range. However, a range filter is much weaker — `BETWEEN 1 AND 7842` might retain files that contain customers 2–7841 that are not in your actual 500-customer set. The file pruning is degraded but still present.

**On the PostgreSQL side:** The compacted BETWEEN range gets embedded into the SQL PostgreSQL receives. PostgreSQL can still use an index range scan, but it now returns every row between the min and max customer ID, not just your 500 specific customers. This is the real culprit — PostgreSQL is streaming back far more rows than necessary, and those extra rows then flow back to Trino to be filtered after the fact.

## How to Verify

Use `EXPLAIN ANALYZE VERBOSE` on your join query. Look for two things:

1. In the dynamic filter section, check if you see `dynamicFilters = {customer_id IN (...)}` (exact list) or `dynamicFilters = {customer_id BETWEEN ... AND ...}` (compacted range). If it's BETWEEN, the compaction threshold kicked in.

2. Check the `Input:` vs `Output:` row count on the PostgreSQL TableScan node in EXPLAIN ANALYZE. If Input is much larger than expected (e.g., Input: 2M rows, Output: 500 rows after filtering), PostgreSQL returned everything in the range and Trino filtered later.

Also tail the PostgreSQL slow query log (`log_min_duration_statement=0` on a replica) — you should see the actual SQL with either an IN-list or BETWEEN range, confirming what the connector sent.

## How to Fix

Raise `domain-compaction-threshold` in your PostgreSQL catalog's properties file. The default of 256 is conservative; for a 500-customer list, bump it higher:

```properties
# In etc/catalog/app_pg.properties (or whatever your PostgreSQL catalog is named):
domain-compaction-threshold=10000
```

This tells the PostgreSQL connector to keep IN-lists intact up to 10,000 distinct values before compacting to a range. Now your 500-customer IN-list arrives in PostgreSQL as-is, PostgreSQL uses the index efficiently, and only those 500 rows are returned.

Or set it per-session before your query:

```sql
SET SESSION app_pg.domain_compaction_threshold = 1024;
-- Replace 'app_pg' with your actual PostgreSQL catalog name (the filename in etc/catalog/ without .properties)
```

**Important:** This is a **per-catalog connector property**, not a cluster-wide setting. Do NOT put it in `etc/config.properties`. And in SET SESSION, you **must use the catalog name prefix** (e.g., `app_pg.`) — bare `SET SESSION domain_compaction_threshold` will error.

## Practical Trade-offs

Larger IN-lists have two small costs:

1. **Wire size between Trino coordinator and workers**, and between Trino and PostgreSQL — larger SQL strings take fractionally longer to ship.
2. **PostgreSQL query planner overhead** — extremely large IN-lists (10s of thousands+) can sometimes confuse PostgreSQL's optimizer. But 1000–5000 is well within safe bounds.

For your use case (500 customers), raising the threshold to 1024 or 2048 is a no-brainer win. The filter stays precise on both the Iceberg and PostgreSQL sides, and you avoid the row-explosion on the PostgreSQL side.
