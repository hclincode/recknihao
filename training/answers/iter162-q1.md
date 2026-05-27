# Iter 162 Q1 — ANALYZE Performance on Large Iceberg Tables

## Answer

## Four hours on a 2TB table: probably normal, but you have options to speed it up

Yes, four hours for a full-table `ANALYZE` on a 2TB events table is within the normal range. `ANALYZE` has to scan the entire table to compute exact counts of distinct values — that's real work, not a quick metadata read. Here's what's actually happening and what you can do.

### Why ANALYZE takes so long

`ANALYZE` walks through every row of your table (or the columns you specify) to build sketches — compact data structures that estimate "how many distinct values are in this column?" These sketches get written to a small Puffin file (a few hundred KB to a few MB) that lives alongside your table's metadata in MinIO. The scan itself is I/O-bound: Trino has to read through all your Parquet files and count distinct values. At 2TB, even at good cluster throughput, that's going to take hours.

### The impact on your running dashboards

The timeout problem is separate from ANALYZE. Your `ANALYZE` statement itself is doing a real table scan, which might be competing for cluster resources with your dashboard queries. However, **ANALYZE does not block other queries** — it's just another query in the queue. If dashboards are timing out while ANALYZE runs, the issue is probably:

1. **Cluster memory or CPU saturation** — ANALYZE is eating resources that would otherwise go to your dashboards.
2. **The real problem underneath** — your join queries may be slow because they lack CBO statistics in the first place. ANALYZE will fix that, but it won't happen until it finishes.

### Your solution: column-targeted ANALYZE

Instead of scanning the entire table, **analyze only the columns you actually filter or join on**:

```sql
-- Fast column-targeted ANALYZE (minutes, not hours):
ANALYZE iceberg.analytics.events 
WITH (columns = ARRAY['user_id', 'tenant_id', 'event_type', 'occurred_at']);
```

Replace those column names with whatever you actually use in WHERE clauses and JOIN predicates. This avoids scanning 100 other columns you don't care about. You can cut runtime by 50-80% depending on how wide your table is.

### If you want to stop the current ANALYZE

You can kill the running query in Trino. It will not corrupt anything — Iceberg transactions are atomic, so either the Puffin file is fully written or not at all. After killing it, run the column-targeted version above instead.

### When to re-run ANALYZE next time

Don't run it on the whole cluster at peak dashboard hours. A few options:

- **Schedule it off-peak** — late night or early morning when dashboard load is low.
- **Partition-by-partition** — if your events table is partitioned by month, analyze only the current/latest month after each batch ingest:

```sql
ANALYZE iceberg.analytics.events 
WITH (partitions = ARRAY[ARRAY['2026-05']], columns = ARRAY['user_id', 'tenant_id']);
```

- **Reduce concurrency** — Trino respects resource groups; you can throttle ANALYZE to use fewer worker threads.

### Verify stats are actually there

After ANALYZE finishes, confirm the CBO now has the stats it needs:

```sql
SHOW STATS FOR iceberg.analytics.events;
```

If `distinct_values_count` is NULL for `user_id` or `tenant_id`, the ANALYZE either didn't finish or didn't cover those columns. In that case, your dashboard join timeouts are likely because the CBO is guessing at join order instead of picking the optimal one.

Once stats are populated and your queries replan (next time they run), you should see faster join execution and fewer timeouts.
