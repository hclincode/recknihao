# Iter289 Q1 — Function-Wrapped Partition Column Breaking Partition Pruning

## Answer

Yes — wrapping the partition column in `DATE()` is exactly why Trino is scanning every file. The fix is a TIMESTAMP literal range predicate on the raw column.

## What's happening

Your table is partitioned by `day(event_time)`, meaning Iceberg splits data into separate Parquet files per day. Partition pruning is a **planning-time** optimization: before reading any data, Trino inspects which day-partitions match your WHERE clause and skips the rest.

The critical constraint: this evaluation happens at planning time, before any data is read. Trino can evaluate `event_time >= TIMESTAMP '2026-04-27 00:00:00'` at planning time — it just compares against the partition boundaries. But `DATE(event_time) >= DATE('2026-04-27')` requires applying a function to values it hasn't read yet. Trino gives up on partition pruning and falls back to opening every file, applying `DATE()` at runtime.

## The fix

Use a TIMESTAMP range predicate on the raw column:

```sql
-- WRONG: full table scan (hundreds of files, all partitions)
WHERE DATE(event_time) >= DATE('2026-04-27')

-- RIGHT: partition-pruned to 30 days (~30 files)
WHERE event_time >= TIMESTAMP '2026-04-27 00:00:00'
  AND event_time < TIMESTAMP '2026-05-27 00:00:00'
```

Trino can evaluate this at planning time: it checks each day-partition boundary against the range and skips everything outside it. On a 30-day window, you go from scanning every historical partition to reading roughly 30 files.

## Why Postgres intuition doesn't apply

In Postgres, wrapping an indexed column in a function can still allow index use (with function-based indexes or when the optimizer recognizes the pattern). In Iceberg, partition pruning is **file-level** and **planning-time** — no functions can be evaluated during planning, so any function applied to the partition column silently disables pruning. There's no equivalent to Postgres's function-based indexes.

## What about CAST?

Trino has special-case optimizer logic that may recognize `CAST(event_time AS DATE) >= DATE('2026-04-27')` and rewrite it to allow pruning. But this is version-dependent and fragile — a Trino upgrade can silently break it. The TIMESTAMP-literal range approach is guaranteed to work on every version.

## Verifying with EXPLAIN

Before running, confirm pruning is active:

```sql
EXPLAIN
SELECT *
FROM iceberg.analytics.events
WHERE event_time >= TIMESTAMP '2026-04-27 00:00:00'
  AND event_time < TIMESTAMP '2026-05-27 00:00:00';
```

Look for `constraint on [event_time]` in the `TableScan` output — that annotation means Iceberg received the predicate and will prune files at scan time.

With the broken version (`DATE(event_time) >= ...`), the predicate appears in a `ScanFilterProject` above the `TableScan` instead — that means Trino is filtering in memory after reading everything.
