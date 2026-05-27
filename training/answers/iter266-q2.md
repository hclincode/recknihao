# Iter266 Q2 — Join Between Postgres and Iceberg Is Slower Than Expected: Dynamic Filtering

## Answer

Yes, Trino is capable of using Postgres results to narrow down the Iceberg scan — this feature is called **dynamic filtering** (also known as runtime join pruning). However, it only works under specific conditions, and if your query plan shows a full Iceberg scan, one of those conditions is probably not being met.

### How Dynamic Filtering Works (The Mental Model)

Imagine this join:

```sql
SELECT e.event_id, e.event_time, c.customer_name
FROM iceberg.analytics.events e
JOIN app_pg.public.customers c ON e.customer_id = c.id
WHERE e.event_date >= CURRENT_DATE - INTERVAL '7' DAY;
```

Here's what Trino does under the hood with dynamic filtering:

1. **Execute the small side first (Postgres).** Scan the `customers` table and return (say) 5,000 customer IDs.
2. **Derive a runtime filter.** Trino collects those 5,000 customer IDs into an `IN` list: `customer_id IN (1, 2, 3, ..., 5000)`.
3. **Push that IN-list to the Iceberg side.** Before reading the event table, Trino tells the Iceberg connector: "only scan events where `customer_id` matches one of these 5,000 values."
4. **Iceberg skips irrelevant files.** The Iceberg connector uses the IN-list to skip data files whose `customer_id` values don't overlap the list — dramatically reducing the I/O.

Without dynamic filtering, Trino scans every event in the table and filters in Trino's workers — slow and expensive.

### Three Reasons Dynamic Filtering Might Not Fire

#### 1. The Join Direction Is Wrong (Most Common)

Dynamic filtering flows **from the smaller table TO the larger table**. Trino calls the smaller table the **build side** (it builds the filter) and the larger table the **probe side** (it applies the filter).

If Trino doesn't realize your Postgres table is small, it may choose the wrong join order. You can force the right order by putting the small table on the appropriate side:

```sql
-- INNER JOIN: put the small table anywhere — Trino should pick the right order
-- if statistics are up to date. Or rewrite explicitly:
SELECT e.event_id, c.customer_name
FROM app_pg.public.customers c
JOIN iceberg.analytics.events e ON e.customer_id = c.id;
```

For LEFT JOIN: the small table typically goes on the **left** (it becomes the build side):
```sql
SELECT e.event_id, c.customer_name
FROM app_pg.public.customers c
LEFT JOIN iceberg.analytics.events e ON e.customer_id = c.id;
```

#### 2. The Join Key Is Not a Simple Column Reference

Dynamic filtering only works when the join key is a direct column-to-column equality match. If you wrap the column in a function, the filter won't push:

```sql
-- WRONG — function on the Iceberg column prevents dynamic filter
JOIN app_pg.public.customers c ON CAST(e.customer_id AS VARCHAR) = c.id;

-- RIGHT — join on the raw columns
JOIN app_pg.public.customers c ON e.customer_id = c.id;
```

Inequalities (`>`, `<`, `BETWEEN`) also don't trigger dynamic filtering — it only works on equality joins (`=`).

#### 3. Trino Timed Out Waiting for the Filter

Dynamic filtering requires Trino to wait for the small (Postgres) side to finish executing before applying the filter to the large (Iceberg) side. There's a configurable timeout. If your Postgres query is slow, Trino may give up and start scanning Iceberg without the filter.

The timeout is controlled by `iceberg.dynamic-filtering.wait-timeout` in the Iceberg catalog configuration:

```properties
# etc/catalog/iceberg.properties
iceberg.dynamic-filtering.wait-timeout=20s
```

The default is 1 second — very short. If your Postgres side takes longer than that (common for large dimension tables), raise this value to 20–30 seconds.

If you increase the timeout but dynamic filtering still doesn't help, check if the Postgres query itself is slow:

```sql
-- Run this directly to time the Postgres side alone
SELECT id FROM app_pg.public.customers;
```

If it's slow, add a Postgres index: `CREATE INDEX ON customers(id);`

### How to Verify Dynamic Filtering Is Working

Run `EXPLAIN ANALYZE` on your join:

```sql
EXPLAIN ANALYZE
SELECT e.event_id, c.customer_name
FROM iceberg.analytics.events e
JOIN app_pg.public.customers c ON e.customer_id = c.id
WHERE e.event_date >= CURRENT_DATE - INTERVAL '7' DAY;
```

**If dynamic filtering is active**, the EXPLAIN output shows a `DynamicFilter` reference in the Iceberg TableScan node, and the `Input:` row count on the Iceberg scan will be much smaller than the total table size.

**If dynamic filtering is NOT active**, the Iceberg TableScan shows `Input: [full table size]` rows with no dynamic filter — that's your signal to check reasons 1–3 above.

Compare:
- `Input: 5,200,000 rows (450MB)` — dynamic filtering NOT working (full scan)
- `Input: 52,000 rows (4.5MB)` — dynamic filtering working (filtered before scan)

### Why the Join Can't Be Pushed to Postgres or Iceberg

You might wonder: "why doesn't Trino tell Postgres to join the Iceberg table directly?" — it can't. Postgres has no connector to Iceberg (it can't read S3/MinIO files). The same is true the other way. **The join always executes on Trino workers.** Dynamic filtering is how Trino avoids reading unnecessary data from Iceberg — it's the closest you can get to "the small side narrows the large side."

### Quick Checklist — If Your Join Is Still Scanning Too Much Iceberg Data

1. **Verify join direction**: Put the small Postgres table as the build side. For INNER JOINs, Trino's optimizer usually handles this automatically if statistics are current; for outer joins, be explicit.

2. **Check the join key**: Make sure it's a direct column reference (`e.customer_id = c.id`), not a computed expression (`CAST(e.customer_id AS VARCHAR) = c.id`).

3. **Raise the dynamic filter timeout** in the Iceberg catalog config: `iceberg.dynamic-filtering.wait-timeout=20s`

4. **Check Postgres performance**: If the Postgres side is slow, add an index on the join column.

5. **Add an Iceberg partition filter**: Even with dynamic filtering, add a date/time filter if your Iceberg table is partitioned by date — that eliminates entire partitions before dynamic filtering even applies:

```sql
-- Add this even if you also have dynamic filtering
WHERE e.event_date >= CURRENT_DATE - INTERVAL '7' DAY
```

6. **Run EXPLAIN ANALYZE**: Look at `Input:` row count on the Iceberg `TableScan` operator. If it equals the full table size, dynamic filtering is not working.

### Summary

| Symptom | Cause | Fix |
|---|---|---|
| Iceberg scan reads full table | Dynamic filtering not firing | Check join direction, join key type, wait-timeout |
| Join key has function (`CAST`, etc.) | Function blocks filter pushdown | Rewrite join key to bare column reference |
| Dynamic filtering fires but scan still large | Iceberg not partitioned on join key | Add partition pruning with `WHERE event_date = ...` |
| Postgres side slow | Timeout before filter is ready | Add index to Postgres join column; raise `wait-timeout` |
