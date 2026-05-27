# Iter 161 Q1 — Trino CBO / ANALYZE TABLE: Why Statistics Matter for Join Order

## Answer

## Why your join order is slow — and what statistics are actually for

Your intuition is correct: Trino absolutely does already know how many rows are in each table. The problem is not about table size — it's about something much more subtle.

### The core issue: join order decisions need more than table size

When Trino plans a join, it doesn't just look at the total row count. It needs to decide:
- Which table should be loaded into memory as a hash table ("the build side")?
- Which table should be streamed past that hash table ("the probe side")?
- Should it broadcast that hash table to every worker, or shuffle both sides?

Making the wrong call here means your query runs 5 seconds instead of 45 minutes on the same data. The component making these decisions is called the **cost-based optimizer**, or CBO.

To pick the right join strategy, the CBO needs to estimate how many rows each table will produce *after* your WHERE filters are applied. It's easy to know a table has 500M rows total — but if your filter is `WHERE plan = 'enterprise'` and enterprise accounts are rare, maybe only 50K rows match. The CBO needs to know that difference.

### What statistics actually capture

Iceberg automatically collects a few things on every write:
- Minimum and maximum value per column per file (used to skip entire files if they can't match your WHERE clause)
- Row count per file

But it **does NOT** auto-collect **NDV** — that's "number of distinct values." NDV is what the CBO desperately needs. For example:
- The `tenants` table has how many distinct tenant IDs? 250? 50 million?
- The `events` table has how many distinct `user_id` values in the month you're querying?

Without NDV, the CBO falls back to rough guesses. It might assume "joining these tables produces 10% of the larger side's rows," which can be wildly wrong for skewed data — like when one customer generates 80% of your events.

### What ANALYZE actually does

When you run `ANALYZE TABLE iceberg.analytics.events`, Trino:
1. Scans every row in the table
2. Computes the count of distinct values for each column
3. Writes those numbers into a small binary file (called a **Puffin file**) stored in MinIO alongside your table metadata

The whole operation is a real query scan — it takes from seconds (small tables) to minutes (very large ones). The result is stored permanently, and the CBO uses it on every future query plan.

### Does it run automatically?

No. Statistics do **not** auto-update when new data arrives. A reasonable schedule is **weekly**, or right after any large data ingest, because:
- If you add millions of new rows without re-running ANALYZE, the old stats become stale, and the CBO goes back to guessing again.
- Stale stats are worse than no stats, because they're confidently wrong.

### When you actually need it

The biggest wins come from running ANALYZE on tables that:
- Appear in **multi-table joins** (3+ tables)
- Have **skewed data** (one tenant generates 80% of events, for instance)
- Join a large fact table to a small dimension (like `events` × `customers`)

For example, a query joining `events` → `users` → `tenants` will benefit hugely from ANALYZE on all three tables.

### How to check if it's the problem

Run this to see what statistics the CBO currently knows:

```sql
SHOW STATS FOR iceberg.analytics.events;
```

If the `distinct_values_count` column is NULL for your join keys (like `user_id` or `tenant_id`), ANALYZE hasn't been run — that's the problem. After running `ANALYZE iceberg.analytics.events`, re-run that SHOW STATS and you'll see real numbers.

### Quick fix

1. Identify the 3–5 tables you join most often (usually a fact table + dimensions).
2. Run `ANALYZE iceberg.analytics.events WITH (columns = ARRAY['user_id', 'tenant_id'])` specifying just the join key columns (faster than scanning the whole table).
3. Do the same for each other table in your frequent joins.
4. Schedule it weekly in your data pipeline.

After that, when Trino re-plans the same query, the CBO will pick the right join order because it now has accurate numbers to estimate cost with.
