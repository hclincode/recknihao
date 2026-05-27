# Answer to Q1: Quick Dashboard Prototyping Without Full Table Scans

## Why LIMIT doesn't help you

First, the trap: `SELECT * FROM events LIMIT 10` still reads every Parquet file that matches your WHERE conditions — `LIMIT` only trims the final result, not the scan cost. On a 400M-row Iceberg table, a bare LIMIT query is just as expensive as no LIMIT at all.

You need two techniques together: narrow the data scope first with a partition filter, then sample from that narrower slice.

## The practical approach: TABLESAMPLE + partition filter

Instead of:
```sql
-- Slow: full 400M-row scan, then trim
SELECT feature_name, COUNT(*) as events
FROM events
GROUP BY feature_name
LIMIT 10;
```

Do this:
```sql
-- Fast: prune to recent data first, then sample
SELECT feature_name, COUNT(*) as events
FROM events TABLESAMPLE BERNOULLI (5)
WHERE occurred_at >= CURRENT_DATE - INTERVAL '7' DAY
GROUP BY feature_name
ORDER BY events DESC;
```

**What each part does:**

1. `WHERE occurred_at >= ...` — Iceberg skips all partitions older than 7 days (partition pruning). You're now working with a slice of the table, not all 400M rows.
2. `TABLESAMPLE BERNOULLI (5)` — of the remaining rows, keep roughly 5% selected randomly. "BERNOULLI" means each row has a 5% independent chance of inclusion. The number is a percentage: `BERNOULLI (1)` = 1%, `BERNOULLI (10)` = 10%.

**Result**: instead of scanning 400M rows, you scan ~7 days (~20M rows), then sample 5% (~1M rows). Query time drops from minutes to seconds.

## Adjusting the sample size

| Sample | Speed | Use when |
|---|---|---|
| `BERNOULLI (1)` | Fastest | Heavy GROUP BYs on many dimensions |
| `BERNOULLI (5)` | Fast | Checking aggregation shapes — good default |
| `BERNOULLI (10)` | Medium | Closer to final accuracy, still much faster |

Start with 5%, verify the aggregation shape looks reasonable (do the feature breakdowns make sense? any obvious outliers?), iterate the query structure, then run the full query once on your final design.

## Approximate functions for cardinality checks

When testing queries that count distinct users or compute percentiles, use approximate versions during exploration:

```sql
SELECT
  feature_name,
  approx_distinct(user_id) AS approx_users,   -- ~2% error, 10x-50x faster
  COUNT(*) AS total_events,
  approx_percentile(load_time_ms, 0.95) AS p95_load
FROM events TABLESAMPLE BERNOULLI (5)
WHERE occurred_at >= CURRENT_DATE - INTERVAL '7' DAY
GROUP BY feature_name
ORDER BY approx_users DESC;
```

`approx_distinct()` uses HyperLogLog — ~2% error, no shuffle, runs in one pass. `approx_percentile()` uses T-Digest. These are perfect for "does this breakdown look reasonable?" During prototyping the ~2% error is irrelevant. Once you've finalized the query design, switch back to exact `COUNT(DISTINCT)` only if the production dashboard requires it.

## Your iteration workflow

1. **Design phase**: Use `TABLESAMPLE BERNOULLI (5)` + 7-day partition filter + approx functions. Queries run in seconds. Iterate freely.
2. **Validation phase**: Remove TABLESAMPLE, run the full query once to get baseline numbers. Takes 3-5 minutes, but you only do this once per finalized design.
3. **Production phase**: If this dashboard will be queried repeatedly, build a rollup table (see below).

## The production fix: pre-aggregated rollup tables

Sampling gets you to a good query design quickly. But the production dashboard still hits 400M rows on every refresh. The real fix is a pre-aggregated rollup table — compute the aggregations once nightly, then point the dashboard at the tiny result table:

```sql
-- Build once nightly (via dbt or a Spark job)
CREATE TABLE events_by_feature_daily AS
SELECT
  CAST(occurred_at AS DATE)  AS event_date,
  feature_name,
  COUNT(*)                   AS event_count,
  COUNT(DISTINCT user_id)    AS user_count
FROM events
GROUP BY 1, 2;

-- Dashboard query: milliseconds, no sampling needed
SELECT feature_name, SUM(event_count) AS total_events
FROM events_by_feature_daily
WHERE event_date >= CURRENT_DATE - INTERVAL '30' DAY
GROUP BY feature_name;
```

This trades a single 2-minute nightly compute job for eliminating the 3-5 minute dashboard scan on every refresh. If your dashboard refreshes every 5 minutes, you've replaced 288 × 5-minute scans per day with one 2-minute job — roughly 95% cost reduction.

## Key takeaway

Combine a partition filter (`WHERE occurred_at >= ...`) with `TABLESAMPLE BERNOULLI (5)` for fast exploratory queries during design. Once the query shape is right, validate once against the full data, then build a rollup table for the production dashboard so repeated queries are fast without sampling.
