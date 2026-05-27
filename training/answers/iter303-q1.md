# Answer to Q1: Rolling WAU/MAU Without Re-Scanning Raw Events — HLL Sketch Tables

## Why re-scanning every time is slow

Each time you run "count distinct users in the last 7 days," Trino must:
1. Scan every partition in the last 7 days from the raw events table
2. Extract the `user_id` column from all those rows
3. Deduplicate them — Trino performs an extra shuffle pass partitioned by `user_id` (on top of the GROUP BY shuffle), and each worker holds all distinct values for its groups in memory to eliminate duplicates

This multi-shuffle overhead grows with the table. Even with columnar storage and partition pruning, deduplicating millions of distinct users from 500M rows doesn't scale for dashboard page loads.

## The HyperLogLog sketch pattern (production solution)

Build a small daily sketch table once per night, then merge sketches at query time for any window — no re-scanning raw events after the initial build.

### Step 1: Build the daily sketch table (nightly job)

```sql
-- Run once per night (Spark job, dbt model, or Airflow task)
CREATE TABLE iceberg.analytics.daily_user_hll AS
SELECT
    event_date,
    approx_set(user_id) AS user_id_hll
FROM iceberg.analytics.events
GROUP BY event_date;
```

`approx_set(user_id)` builds a **HyperLogLog sketch** — a tiny fixed-size binary blob (a few KB per day) that encodes the approximate distinct user count for that day. Result type is `HyperLogLog`, stored as a binary column in Iceberg.

### Step 2: Query rolling 7-day WAU without touching raw events

```sql
SELECT
    s1.event_date                       AS window_end,
    cardinality(merge(s2.user_id_hll))  AS wau_7d
FROM iceberg.analytics.daily_user_hll s1
JOIN iceberg.analytics.daily_user_hll s2
  ON s2.event_date BETWEEN s1.event_date - INTERVAL '6' DAY
                       AND s1.event_date
GROUP BY s1.event_date
ORDER BY s1.event_date;
```

For 30-day MAU, change the INTERVAL to `'29' DAY`. Same sketch table, different window.

### What the three functions do

- **`approx_set(column)`** — builds a HyperLogLog sketch during the GROUP BY aggregation. Returns a `HyperLogLog` type value, not a count.
- **`merge(hll_column)`** — aggregate function that unions multiple sketches. Merging sketches from days 1–7 is mathematically equivalent to running `approx_distinct` over the union of all users from those 7 days.
- **`cardinality(hll)`** — extracts the approximate distinct count from a merged sketch. Returns `BIGINT`.

## Why this avoids re-scanning

You pay the sketch-building cost **once per day** — a single GROUP BY on only the new partition written that day. Every WAU/MAU query after that reads at most 30 small rows (the daily sketches) from the sketch table and performs a cheap merge.

| Query type | Bytes read | Latency |
|---|---|---|
| Re-scan raw events (7-day WAU) | Several GB | 30–120 seconds |
| Sketch merge (7-day WAU) | ~7 KB (7 rows) | Milliseconds |
| Sketch merge (30-day MAU) | ~30 KB (30 rows) | Milliseconds |

For an ops dashboard refreshing every minute, this difference eliminates the performance problem entirely.

## Example dashboard query

```sql
-- WAU and MAU in one query from the sketch table:
SELECT
    cardinality(merge(CASE WHEN event_date >= CURRENT_DATE - INTERVAL '6' DAY
                           THEN user_id_hll END)
               ) AS wau_7d,
    cardinality(merge(CASE WHEN event_date >= CURRENT_DATE - INTERVAL '29' DAY
                           THEN user_id_hll END)
               ) AS mau_30d
FROM iceberg.analytics.daily_user_hll
WHERE event_date >= CURRENT_DATE - INTERVAL '29' DAY;
```

## Accuracy trade-offs

HyperLogLog has approximately **2.3% relative standard error** by default:
- 68% of estimates within ±2.3% of the true count
- 95% within ±4.6%
- Not a hard ceiling — some estimates can be further off on very small cohorts

**For internal ops dashboards:** 2% error is invisible and acceptable. WAU of 48,200 vs 49,000 doesn't change any operational decision.

**For customer-facing billing or compliance:** Use exact `COUNT(DISTINCT)` and run it as a nightly batch job, not on page load.

**Validate on your real data before committing:**
```sql
SELECT
    COUNT(DISTINCT user_id)  AS exact_count,
    approx_distinct(user_id) AS approx_count,
    ROUND(100.0 * (approx_distinct(user_id) - COUNT(DISTINCT user_id))
          / COUNT(DISTINCT user_id), 3) AS pct_error
FROM iceberg.analytics.events
WHERE event_date = DATE '2026-05-26';
```
Run on 5–10 different days. If error consistently stays under ~1.5%, sketches are safe for your use case.

## Verify the optimization landed

Run `EXPLAIN ANALYZE` on both queries and compare the "Input: X bytes" line. The sketch-based query should show ~30 KB instead of several GB. If bytes scanned didn't drop, the rewrite didn't land as expected.

## Implementation steps

1. **Create `daily_user_hll` as an Iceberg table** (partitioned by `event_date`)
2. **Add it to your nightly pipeline** — run after each day's events are ingested
3. **For today's incomplete data:** union the sketch table with an `approx_distinct` on today's events only (one partition, fast)
4. **Point your dashboard** at the sketch merge query instead of the raw events scan
