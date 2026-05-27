# Iter142 Q2 — Answer

**Question**: "One of our customers ran a big export — basically pulling two years of their event data with a bunch of filters and groupings — and Trino just died with some out-of-memory error. We bumped the memory limits a bit and it still failed. I don't really understand why a SELECT query would run out of memory at all. Can you explain what's happening and what we can actually do about it without just throwing more RAM at the problem?"

---

## Why SELECT Queries Use Memory

SELECT queries should just scan files and return rows, right? In theory, yes. In practice, Trino holds significant data in memory during three operations:

### 1. Joins (the biggest culprit)

When you JOIN two tables, Trino doesn't stream rows through like Postgres pipes them. Instead, it:
- Reads the entire smaller table into a **hash map in memory** (one side of the hash join)
- Streams the larger table and looks up each row against that in-memory map

If your customer's query JOINs a large fact table to another large table without good filters, Trino tries to load millions of rows into memory at once. A 2-billion-row fact table, even if filtered to a subset, can still overwhelm memory if the filter doesn't compress it enough.

### 2. Aggregations (GROUP BY with high cardinality)

When you do `SELECT tenant_id, user_id, COUNT(*) FROM events GROUP BY tenant_id, user_id`, Trino must keep every distinct `(tenant_id, user_id)` pair in a hash table as it scans. For "two years of event data with a bunch of filters and groupings," if those groupings have millions of distinct values, you're forcing Trino to hold all of them simultaneously in memory.

### 3. ORDER BY without LIMIT

`SELECT * FROM events ORDER BY created_at` requires Trino to load the entire result set, sort it in memory, and then return it. Two years of event data can be gigabytes. With a LIMIT clause (`ORDER BY created_at DESC LIMIT 1000`), Trino can use a top-N algorithm that holds only 1,000 rows. Without LIMIT, it holds everything.

### 4. Spill-to-disk (the safety net that sometimes fails)

Trino does have a feature to spill large intermediate results to disk when memory gets full. But spill has a cost — it's much slower than in-memory processing, and if the data is truly massive or fragmented into many small spillings, disk I/O can become the bottleneck and the query still times out or fails.

**Your symptom — "we bumped memory and it still failed" — suggests the query is hitting either a hard memory ceiling, or the spill-to-disk logic itself is exhausting temporary disk space.**

---

## How Trino's Memory Model Works

Understanding the three layers of memory limits will help you diagnose the real issue:

### Layer 1: Per-query memory limit

Set in the Trino coordinator config (`query.max-memory-per-node`). It caps how much memory one query can use on a single worker node.

- If a query tries to allocate beyond this, the worker kills the task with an `EXCEEDED_MEMORY_LIMIT` error.
- This is not a cluster-wide limit — with 10 workers, you can have 10 queries each using 4 GB = 40 GB total.

### Layer 2: Per-resource-group memory limit

On your production stack, Trino is configured with resource groups (used for multi-tenant query isolation). The resource groups can limit how much memory a tenant or query source can consume:
- `softMemoryLimit`: queues new queries when the group exceeds a threshold.
- If set to `"20%"`, a tenant's queries share that percentage of cluster memory. Queries already running keep running, but new ones queue.

### Layer 3: Cluster-wide limits

The sum of all worker node memory available for Trino. Every concurrent query shares this pool.

### The interaction that causes OOM

Your customer's export query runs on several workers simultaneously:
- Query allocates memory on each worker for hash tables / aggregation buffers.
- If that query also has sub-tasks (exchanges between workers), each sub-task reserves memory.
- Multiple concurrent queries together exceed cluster memory.

**Result: OOM**, because the memory model doesn't prevent a single large query from saturating the cluster when multiple queries run concurrently.

---

## What Specific Query Patterns Cause OOM

These are the red flags in a two-year export query:

### 1. Unfiltered two-year aggregation
```sql
SELECT event_type, COUNT(*) 
FROM events 
GROUP BY event_type
```
Over two years, this scans gigabytes. If `event_type` has high cardinality, Trino keeps a massive hash table. **Fix: narrow the time range** (e.g., last 30 days at a time, then UNION).

### 2. Multi-column GROUP BY with high cardinality
```sql
SELECT tenant_id, user_id, event_date, COUNT(*) 
FROM events 
WHERE event_date >= CURRENT_DATE - INTERVAL '730' DAY
GROUP BY tenant_id, user_id, event_date
```
Three dimensions × millions of unique tuples = memory explosion. **Fix: pre-aggregate daily**, then query the aggregated table.

### 3. JOIN without partition filters
```sql
SELECT e.*, u.display_name 
FROM events e 
JOIN users u ON e.user_id = u.user_id
```
If both tables are filtered poorly, you're joining millions against millions. **Fix: add partition filters on both sides**.

### 4. ORDER BY full dataset without LIMIT
```sql
SELECT * FROM events 
WHERE event_date >= CURRENT_DATE - INTERVAL '730' DAY 
ORDER BY event_id
```
Trino must materialize all rows, sort them, return them. **Fix: add `LIMIT` or paginate the export**.

### 5. Window functions over ungrouped data
```sql
SELECT *, ROW_NUMBER() OVER (ORDER BY event_date) 
FROM events
```
Trino must hold all rows to compute the window. **Fix: partition the window** (`OVER (PARTITION BY user_id ORDER BY event_date)`).

---

## How to Diagnose Which Part Is Consuming Memory

### Step 1: Check the Trino UI

Open `http://trino-coordinator:8080/ui/queries`. Look for your export query:
- **Memory used**: shown per-query and per-task.
- **Wall time vs CPU time**: if wall >> CPU, I/O-bound. If close, compute-bound (aggregation or join).

### Step 2: Run EXPLAIN (no execution)
```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT ... your export query ...
```
This shows the query plan — the fragment graph and data flows — without executing the query.

Look for:
- **Aggregation fragments**: if aggregation output cardinality is high, memory will spike.
- **Hash joins**: Trino will show the join type. If it's a hash join and tables are large, memory is at risk.

### Step 3: Run EXPLAIN ANALYZE on a smaller dataset
```sql
EXPLAIN ANALYZE
SELECT ... your export query ... 
WHERE event_date >= CURRENT_DATE - INTERVAL '7' DAY
LIMIT 100000
```
This **executes** the query on a smaller slice so you can see:
- **Actual input rows vs expected rows** (did a filter not work?).
- **Output rows from each stage** (where does cardinality explode?).
- **Wall time**: how long it actually took.

Scale the memory requirement linearly: if 7 days used 3 GB, 730 days would use ~315 GB.

### Step 4: Check for missing partition filters
```sql
SHOW CREATE TABLE iceberg.analytics.<your_table>;
```
Look at the `PARTITIONED BY` clause. If your WHERE clause doesn't filter on those partition columns, you're scanning the entire table. A query that should hit one month of partitions may be scanning two years.

---

## Fixes That Don't Require Adding RAM

### 1. Narrow the time range and paginate

Instead of exporting two years at once, export 30 days at a time:

```sql
-- Run once per month, collect results
SELECT * FROM events 
WHERE event_date >= DATE '2024-01-01' AND event_date < DATE '2024-02-01'
```

Seven days of data uses ~100x less memory than two years.

### 2. Pre-aggregate in a rollup table

Don't run heavy GROUP BY on raw events. Build a nightly rollup:

```sql
-- Run nightly via Spark job
INSERT INTO iceberg.analytics.daily_events_rollup
SELECT tenant_id, user_id, event_date, event_name, COUNT(*) AS cnt
FROM iceberg.analytics.events
WHERE event_date = CURRENT_DATE - INTERVAL '1' DAY
GROUP BY tenant_id, user_id, event_date, event_name;
```

Your customer queries the rollup table instead of raw events — 1000x smaller, queries in seconds.

### 3. Add partition filters

The #1 performance win is always partition pruning. Check your WHERE clause:

```sql
-- BEFORE (scans entire table, high memory)
SELECT tenant_id, COUNT(*) 
FROM events 
WHERE tenant_id = 'customer_acme'

-- AFTER (prunes to matching partitions, much less memory)
SELECT tenant_id, COUNT(*) 
FROM events 
WHERE event_date >= CURRENT_DATE - INTERVAL '730' DAY
  AND tenant_id = 'customer_acme'
GROUP BY tenant_id
```

Adding `event_date >= ...` where the table is partitioned by `event_date` tells Trino to skip files outright, reducing memory pressure before a single row is processed.

### 4. Use `approx_distinct` instead of `COUNT(DISTINCT)`

```sql
-- Uses memory for every distinct value
SELECT COUNT(DISTINCT user_id) 
FROM events

-- Uses a fixed-size HyperLogLog sketch (~2% error, 100x less memory)
SELECT approx_distinct(user_id) 
FROM events
```

For an export report, 2% error on a million-user count is usually acceptable. Saves gigabytes of memory.

### 5. Use INSERT INTO ... AS SELECT for large exports

Instead of streaming results through Trino's memory back to the client:

```sql
INSERT INTO iceberg.analytics.customer_acme_export
SELECT * FROM events 
WHERE tenant_id = 'customer_acme'
  AND event_date >= CURRENT_DATE - INTERVAL '730' DAY;
```

This writes results to MinIO instead of through Trino's network buffer. The customer then downloads the resulting Parquet files directly from MinIO. Much better for multi-GB exports.

### 6. Avoid cross joins and Cartesian products

A query like:
```sql
SELECT DISTINCT e1.user_id, e2.user_id
FROM events e1
JOIN events e2 ON e1.tenant_id = e2.tenant_id
```

creates a Cartesian product if there's no other join condition. Two years × two copies = memory explosion. **Add a proper join condition** or restructure the query.

---

## When to Add Resources and How to Size Memory

Add RAM only if:

1. **You've applied all the above fixes and the query is still hitting the ceiling** — the query is legitimately that large and memory-efficient.

2. **Concurrency is the problem, not query size** — if 10 small queries run in parallel and together they exceed cluster memory, add workers (horizontal scaling) instead of RAM per worker.

3. **You've measured the query's actual memory need** using the Trino UI during a run on a subset of data.

### Sizing approach

If a query on 30 days of data uses 3 GB, a 730-day query will use roughly 73 GB per query (linear scaling).

Add 2x headroom for concurrent queries:
- 730 days = 73 GB per query.
- 3 concurrent queries = 219 GB.
- 2x headroom = 438 GB cluster memory.
- Spread across 8 workers = 55 GB per worker.

Before reaching for 55 GB workers, ask: **do you actually need 730 days of raw data in one query?** Usually the answer is no. Pre-aggregate, partition, and narrow the window first.

---

## Key Configuration to Check

On your production stack:

1. **Verify `query.max-memory-per-node`** in `etc/config.properties`:
   ```
   query.max-memory-per-node=4GB
   ```
   If this is very low (e.g., 1 GB) and you didn't raise it, that's your ceiling.

2. **Check resource group limits** — a customer assigned to a group with a 20% memory cap can only use that fraction of cluster memory, even if the cluster is idle.

3. **Verify spill is enabled** — if spill is disabled, queries that exceed memory fail immediately instead of spilling to disk. Enable it for large export workloads.

---

## Summary

| Root cause | Symptom | Fix (no more RAM) |
|---|---|---|
| Missing partition filter | Scans all 2 years even with WHERE | Add `event_date >= ...` matching the partition spec |
| High-cardinality GROUP BY | Memory spike during aggregation | Pre-aggregate nightly; query rollup table |
| ORDER BY without LIMIT | Full dataset materialized | Add LIMIT or paginate export |
| Large hash join | Memory spike during join | Filter join inputs; broadcast small tables |
| Streaming to client | Network buffer exhausted | Use INSERT INTO ... AS SELECT, download from MinIO |

For your customer: help them define a narrower export scope (last 90 days) or build a pre-aggregated export table (daily rollups) that they can query in seconds instead of hitting OOM. Only reach for more RAM after the query is as efficient as it can be.
