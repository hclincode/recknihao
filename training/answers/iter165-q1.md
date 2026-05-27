# Iter 165 Q1 — Federation Join Scaling from 5K to 120K Accounts

## Answer

Your query is experiencing a **scaling problem with cross-catalog joins**, and the issue is predictable: as the Postgres side grows from 5,000 to 120,000 rows without a selective filter, the join becomes exponentially more expensive.

## The core problem

When Trino joins a 400M-row Iceberg table against a Postgres table in a cross-catalog join, the join **does not execute on Postgres** — it executes on Trino workers. This means:

1. Trino scans your Postgres `customers` table over JDBC and pulls rows into memory.
2. Trino builds a hash table from those rows.
3. Trino probes the Iceberg events table against that hash table.

**With 5,000 customer rows**, this was fast because the hash table was small and Trino could apply **dynamic filtering**: it derived a filter (an IN-list of customer IDs from the 5,000 rows) and pushed it into the Iceberg scan, pruning files before reading them.

**With 120,000 customer rows**, the hash table is now 24× larger. More critically, the dynamic filter becomes much less effective — you're now pushing a 120K-row IN-list into Iceberg, which is harder to compress and apply for file pruning. Additionally, you're transferring 120K rows over JDBC instead of 5K, and the join itself on workers is more expensive.

## This is not a Postgres indexing problem

Adding indexes on the Postgres side will not help because Postgres is not executing the join. The entire join happens on Trino workers, and the Postgres side is treated as a "dimension" being fetched.

## Your options, in priority order

### Option 1: Add a selective WHERE clause on the Postgres side (immediate, minimal change)

If your query currently does this:

```sql
SELECT ...
FROM iceberg.analytics.events e
JOIN app_pg.public.customers c ON e.customer_id = c.id
...
```

Make it selective:

```sql
SELECT ...
FROM iceberg.analytics.events e
JOIN app_pg.public.customers c ON e.customer_id = c.id
WHERE c.plan = 'enterprise'  -- or any other column that narrows the set
...
```

A "large × large" cross-catalog join is survivable in production if and only if at least one side has a selective WHERE that reduces it to a few tens of thousands of rows. If you can filter to 5–10K customers instead of 120K, dynamic filtering fires properly again and the query becomes fast.

### Option 2: Ingest the customer table into Iceberg (medium-term, architectural)

Move the Postgres `customers` table into Iceberg as a regularly-refreshed table. Then both tables are in the `iceberg` catalog and the join becomes **intra-catalog**:

```sql
SELECT ...
FROM iceberg.analytics.events e
JOIN iceberg.app.customers c ON e.customer_id = c.id  -- now both in Iceberg
...
```

This enables:
- **Columnar I/O** instead of JDBC row-by-row reads.
- **Cost-based optimizer (CBO) statistics** via `ANALYZE`, which picks a better join plan.
- No JDBC overhead for every query.

Typical speedup: 2–10× for this pattern.

### Option 3: Hybrid pattern with a live-tail view (if freshness is a concern)

If you need minute-level freshness on customer data, use a **UNION ALL view** that stitches Iceberg (historical) + Postgres (live tail):

```sql
CREATE OR REPLACE VIEW customers_live AS
SELECT * FROM iceberg.app.customers WHERE updated_at < (CURRENT_TIMESTAMP - INTERVAL '1' HOUR)
UNION ALL
SELECT * FROM app_pg.public.customers WHERE updated_at >= (CURRENT_TIMESTAMP - INTERVAL '1' HOUR)
```

Then join against the view. The Iceberg side gets partition pruning; the Postgres side is small (only recent changes) and dynamic filtering is effective.

## What you should **not** do

- Do **not** add connection pooling properties like `connection-pool.enabled` to your Trino Postgres catalog file. OSS Trino 467 does not support native JDBC connection pooling for the PostgreSQL connector — those properties are silently ignored.
- Do **not** assume Postgres indexes will help — the join is not running in Postgres.

## Immediate next step

Check your query's EXPLAIN plan to see if dynamic filtering is firing. Run:

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT ...
FROM iceberg.analytics.events e
JOIN app_pg.public.customers c ON e.customer_id = c.id
...
```

Look for `dynamicFilters = {...}` on the Iceberg scan. If it's present but the query is still slow, check that the filter is actually effective at runtime with `EXPLAIN ANALYZE` and look at `dynamicFilterSplitsProcessed` on the Iceberg side. Non-zero means the filter is working. Zero means it's not firing in time — raise `iceberg.dynamic_filtering_wait_timeout` (default is 1s for the Iceberg connector) to allow more time for the build side.

The scaling cliff you've hit is expected and well-understood. The fix depends on whether you can add filters (fastest) or need to move the table (better long-term).
