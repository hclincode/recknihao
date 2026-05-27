# Iter291 Q2 — Estimating How Much Data a Trino Query Will Scan Against a Large Iceberg Table

## Short answer

You can get a strong pre-run estimate using three approaches in increasing precision:
1. **Mental math from partition structure** — fastest, no query needed
2. **Iceberg metadata table query** — exact file sizes, no data scan
3. **EXPLAIN ANALYZE on a 1-day sample** — real Physical Input bytes, then extrapolate

You cannot get the exact compressed bytes from bare `EXPLAIN` — that number only appears after execution. But the approaches above let you decide whether a query will cost 50 GB or 5 TB before you commit.

---

## Approach 1: Mental math from partition structure

For a 5 TB annual table partitioned by day:
- Average per-day size: 5 TB ÷ 365 ≈ 14 GB raw Parquet
- Parquet compression on event data is typically 5–10x, so compressed ≈ 1.4–2.8 GB/day
- 30-day query: ~42–84 GB compressed reads

This only holds if partition pruning is working — if the WHERE clause doesn't filter on the partition column, assume the full 5 TB.

## Approach 2: Iceberg metadata table (exact file sizes, no data scan)

Iceberg exposes `$files` and `$partitions` metadata tables that show file sizes without touching Parquet data:

```sql
-- Exact bytes in partitions matching your query range
SELECT
  COUNT(*) AS file_count,
  SUM(file_size_in_bytes) / 1024.0 / 1024 / 1024 AS total_gb
FROM iceberg.analytics."events$files"
WHERE partition['day_occurred_at'] >= '2026-05-01'
  AND partition['day_occurred_at'] <  '2026-06-01';
```

This is fast (reads only manifest metadata from MinIO, not Parquet files) and gives you the exact compressed bytes in the partition range. Note: this is file size, not post-column-pruning bytes — actual scan will be less if you SELECT only a few columns.

## Approach 3: EXPLAIN to verify partition pruning is working

```sql
EXPLAIN
SELECT user_id, COUNT(*) AS events
FROM iceberg.analytics.events
WHERE occurred_at >= TIMESTAMP '2026-05-01 00:00:00'
  AND occurred_at <  TIMESTAMP '2026-06-01 00:00:00'
GROUP BY user_id;
```

Look for `constraint on [occurred_at]` in the `TableScan` line. If you see this, partition pruning is active — your estimate from approaches 1–2 is valid. If the predicate is inside `ScanFilterProject` instead, pruning failed and expect the full table scan.

Bare `EXPLAIN` does NOT show `Physical Input` bytes — that only appears in `EXPLAIN ANALYZE` (which executes the query).

## Approach 4: EXPLAIN ANALYZE on a 1-day sample → extrapolate

Run your query on a single day first:

```sql
EXPLAIN ANALYZE
SELECT user_id, COUNT(*) AS events
FROM iceberg.analytics.events
WHERE occurred_at >= TIMESTAMP '2026-05-25 00:00:00'
  AND occurred_at <  TIMESTAMP '2026-05-26 00:00:00'
GROUP BY user_id;
```

Find `Physical Input: X GB` in the output. That's the actual compressed bytes Trino read from MinIO for one day. Extrapolate:
- 1 day = 1.4 GB compressed → 30 days ≈ 42 GB

This is the most accurate pre-run estimate for your full-range query.

---

## When your estimate jumps to the full 5 TB

If any of these apply, assume a full table scan:

| Condition | Why it hurts |
|---|---|
| No partition column in WHERE | Iceberg cannot prune any files |
| `year(occurred_at) = 2026` or `month(occurred_at) = 5` | Non-monotonic — no unwrap rule; Trino scans all files |
| Filter only on non-partition column (e.g., `event_type = 'click'`) | Partition pruning doesn't help |
| Complex arithmetic on partition column | May defeat pruning |

Note: `DATE(occurred_at) = DATE '2026-05-01'` and `date_trunc('day', occurred_at) = DATE '2026-05-01'` are both handled by Trino 467's optimizer and DO enable pruning.

---

## Decision flow

```
1. Does WHERE filter directly on partition column (occurred_at range)?
   YES → estimate = file sizes from $files metadata table, or mental math
   NO → estimate = entire table (5 TB)

2. Verify partition pruning with EXPLAIN — look for 'constraint on [occurred_at]'

3. If uncertain, run EXPLAIN ANALYZE on a 1-day window to get actual Physical Input,
   then multiply by your date range

4. If Physical Input >> your estimate: partition pruning is broken — fix your WHERE clause
```

For your 5 TB table queried by 30 days with a correct partition filter: expect ~42–84 GB compressed I/O, taking 10–30 seconds on a healthy Trino cluster. Multi-TB reads mean your filter isn't pruning.
