# Iter69 Q1 — Answer

**Question**: We have an Iceberg table for user events, partitioned by event timestamp — I think the underlying partitions are by day. When I run a query in Trino like `WHERE event_ts >= '2026-05-01'`, I expect it to only scan data from that date forward. But looking at the query plan, it seems like it's still reading a ton of files, maybe everything. I don't understand what's going wrong. The column I'm filtering on IS the column I partitioned by. Why wouldn't it skip the old partitions? Is there something I have to do differently in how I write the query, or is there something wrong with how the table was set up?

---

## Answer

Partition pruning in Iceberg (what Trino calls "partition skip") is automatic — you don't need to write partition columns explicitly in your query. But there are a few specific things that silently break it. Here are the three most common causes, and how to diagnose which one you have.

### First: verify the table is actually partitioned

Run this:

```sql
SHOW CREATE TABLE iceberg.analytics.user_events;
```

Look for a `partitioning = ARRAY[...]` clause. If it's absent or empty, the table has no partitions and Trino will always scan every file. No amount of WHERE clause tuning will fix that.

If you see `partitioning = ARRAY['day(event_ts)']`, the spec exists. Now diagnose why pruning isn't kicking in.

### Cause 1: Function wrapping defeats partition pruning (most common)

Iceberg's hidden partitioning works by matching your WHERE predicate against the partition transform. The transform is `day(event_ts)`. Trino infers partition pruning from a raw column predicate — but only if the column appears unwrapped in your filter.

These patterns **break pruning**:

```sql
-- BAD: CAST hides event_ts from the planner
WHERE CAST(event_ts AS DATE) >= DATE '2026-05-01'

-- BAD: DATE() function hides event_ts
WHERE DATE(event_ts) >= CURRENT_DATE

-- BAD: any arithmetic on the column
WHERE event_ts + INTERVAL '1' HOUR >= TIMESTAMP '2026-05-01 01:00:00'
```

These patterns **preserve pruning**:

```sql
-- GOOD: raw column, timestamp literal
WHERE event_ts >= TIMESTAMP '2026-05-01 00:00:00'

-- GOOD: raw column, string literal that Trino can cast
WHERE event_ts >= '2026-05-01 00:00:00'
```

When you wrap the partition column in a function, Trino's planner no longer recognizes it as the partition column and falls back to full scan. This is the most common cause of "I filtered on the partition column but it still scans everything."

### Cause 2: Type mismatch between the filter and the partition transform

If `event_ts` is `TIMESTAMP(6)` and your partition is `day(event_ts)`, the filter type must be compatible with a TIMESTAMP comparison. A mismatch between DATE and TIMESTAMP types in the comparison can confuse the planner:

```sql
-- Potentially broken: comparing TIMESTAMP column against DATE literal
WHERE event_ts >= DATE '2026-05-01'
```

Use an explicit TIMESTAMP literal to match the column type:

```sql
WHERE event_ts >= TIMESTAMP '2026-05-01 00:00:00'
```

### Cause 3: Partition spec was added after data was written

This is a subtle one. If you originally created the table without partitioning and then added it with `ALTER TABLE`:

```sql
ALTER TABLE iceberg.analytics.user_events
SET PROPERTIES partitioning = ARRAY['day(event_ts)'];
```

That ALTER changes the spec for **future writes only**. Every file written before the ALTER has no partition metadata — Trino can't prune those files because they're not in any partition. Queries still return correct results, but old data gets fully scanned. If your table was unpartitioned for months, 95%+ of your data falls into this category.

The fix is to rewrite historical data into the new partition layout (run via Spark, not Trino):

```sql
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.user_events',
  options => map(
    'target-file-size-bytes', '268435456',
    'min-input-files', '1'
  )
);
```

This is a one-time operation that migrates all existing files into the new partition structure. After it completes, Trino can prune based on `event_ts`.

### Cause 4: Small files — pruning works but doesn't help

This one is different. Partition pruning might be working correctly, but you have thousands of tiny files within the pruned partition, and file-open overhead dominates.

Check with `EXPLAIN ANALYZE`:

```sql
EXPLAIN ANALYZE
SELECT COUNT(*)
FROM iceberg.analytics.user_events
WHERE event_ts >= TIMESTAMP '2026-05-01 00:00:00';
```

Look at the `Files:` count in the output. If you expected to scan a few weeks of data (say 25 partitions) and the file count is 25,000, your table has the small-files problem. Each file has 10–50 ms of overhead just to open it — 25,000 files = significant overhead before Trino reads a single row.

Fix with compaction:

```sql
-- Run via Spark (not Trino)
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.user_events',
  options => map('target-file-size-bytes', '268435456')
);
```

After compaction, the same 25 partitions become 25 files (or a few per partition), and query latency drops dramatically.

### Diagnostic checklist

1. `SHOW CREATE TABLE iceberg.analytics.user_events` — confirm `partitioning = ARRAY['day(event_ts)']` exists
2. Check your WHERE clause — is `event_ts` raw or wrapped in a function?
3. Check when the partition spec was added — if recently, run `rewrite_data_files` to migrate old files
4. Run `EXPLAIN ANALYZE` on your query — look at `Files:` count; if it's 10× what you expect, run compaction

The most likely fix for "it scans everything even though I filter on the partition column" is item 2 (function wrapping) or item 3 (spec added after data exists). Item 4 (small files) is what causes "it scans the right partitions but is still slow."
