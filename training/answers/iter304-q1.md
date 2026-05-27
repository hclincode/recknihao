# Answer to Q1: HyperLogLog Sketch Storage in Iceberg (Iter 304)

The issue you're hitting is that **Iceberg's Parquet storage format does not natively know how to serialize Trino's `HyperLogLog` type**. The `HyperLogLog` type is an in-engine Trino construct — Parquet has no encoding for it. When you try to write a `HyperLogLog` column directly to Iceberg, the CREATE TABLE fails.

The solution is the **varbinary round-trip pattern**: serialize sketches to binary on write, deserialize on read.

## Why This Happens

Trino's `HyperLogLog` is a runtime data structure (an in-memory probabilistic sketch). It has no persistent representation in Parquet or ORC. When Iceberg's connector tries to map a `HyperLogLog` column to a Parquet schema, it has no native type to use. This is by design — Parquet is a storage format; HyperLogLog is an algorithmic optimization.

## Production-Ready Pattern: Daily Pre-aggregated Sketches

**Step 1: Create the sketch table (nightly, after events arrive)**

```sql
-- Creates one row per day with a HyperLogLog sketch cast to varbinary.
-- CRITICAL: cast the result of approx_set() to varbinary before storing.
CREATE TABLE iceberg.analytics.daily_user_hll
WITH (partitioning = ARRAY['event_date'])
AS SELECT
    event_date,
    CAST(approx_set(user_id) AS varbinary) AS user_id_hll
FROM iceberg.analytics.events
GROUP BY event_date;
```

Why the cast:
- `approx_set(user_id)` returns a `HyperLogLog` type (an in-memory sketch).
- Iceberg/Parquet cannot persist `HyperLogLog` directly.
- `CAST(approx_set(...) AS varbinary)` serializes the sketch to a binary blob (typically a few KB).
- The persisted column type on disk is `varbinary`.

**Step 2: Query rolling 7-day and 30-day windows (query time)**

```sql
-- Compute rolling 7-day WAU
-- CRITICAL: cast varbinary back to HyperLogLog before calling merge().
SELECT
    s1.event_date AS window_end,
    cardinality(merge(CAST(s2.user_id_hll AS HyperLogLog))) AS wau_7d
FROM iceberg.analytics.daily_user_hll s1
JOIN iceberg.analytics.daily_user_hll s2
  ON s2.event_date BETWEEN s1.event_date - INTERVAL '6' DAY
                       AND s1.event_date
GROUP BY s1.event_date
ORDER BY s1.event_date;
```

For 30-day MAU:

```sql
SELECT
    s1.event_date AS window_end,
    cardinality(merge(CAST(s2.user_id_hll AS HyperLogLog))) AS mau_30d
FROM iceberg.analytics.daily_user_hll s1
JOIN iceberg.analytics.daily_user_hll s2
  ON s2.event_date BETWEEN s1.event_date - INTERVAL '29' DAY
                       AND s1.event_date
GROUP BY s1.event_date
ORDER BY s1.event_date;
```

## The Three Primitives

1. **`approx_set(column)` at write time** — builds a HyperLogLog sketch in memory. Returns the `HyperLogLog` type. Must be cast to `varbinary` before storing in Iceberg.

2. **`merge(hll_column)` at read time** — aggregates multiple sketches into one unified sketch. Input MUST be `HyperLogLog` type — if you pass `varbinary` directly, it fails with "Unexpected parameters (varbinary) for function merge". Cast first: `CAST(col AS HyperLogLog)`.

3. **`cardinality(hll)` at read time** — extracts the approximate distinct count from a sketch. Input must be `HyperLogLog`, not `varbinary`.

Merging sketches from days 1–7 is mathematically equivalent to running `approx_distinct` over the union of all users from those 7 days.

## The Double Cast — Common Gotchas

**This fails:**
```sql
-- WRONG — tries to store HyperLogLog directly; Iceberg has no encoding for it.
CREATE TABLE daily_hll AS
SELECT event_date, approx_set(user_id) AS user_id_hll
FROM events
GROUP BY event_date;
-- Error: Unsupported type: HyperLogLog
```

**This also fails:**
```sql
-- WRONG — varbinary cannot be passed directly to merge().
SELECT cardinality(merge(user_id_hll)) FROM daily_hll;
-- Error: Unexpected parameters (varbinary) for function merge
```

**This works:**
```sql
-- CORRECT — serialize on write, deserialize on read.
-- On write:
CREATE TABLE daily_hll AS
SELECT event_date, CAST(approx_set(user_id) AS varbinary) AS user_id_hll
FROM events
GROUP BY event_date;

-- On read:
SELECT cardinality(merge(CAST(user_id_hll AS HyperLogLog)))
FROM daily_hll;
```

## Why This Solves Your Performance Problem

| Query type | Bytes read | Latency |
|---|---|---|
| Re-scan raw events (30-day MAU) | Several GB | 30–120 seconds |
| Sketch merge (30-day MAU) | ~30 KB (30 rows) | Milliseconds |

You pay the sketch-building cost once per day — a GROUP BY on only the new partition written that night. Every WAU/MAU query after that reads at most 30 small rows from the sketch table.

## Dashboard Query (WAU + MAU in one query)

```sql
SELECT
    cardinality(merge(CASE WHEN event_date >= CURRENT_DATE - INTERVAL '6' DAY
                           THEN CAST(user_id_hll AS HyperLogLog) END)
               ) AS wau_7d,
    cardinality(merge(CASE WHEN event_date >= CURRENT_DATE - INTERVAL '29' DAY
                           THEN CAST(user_id_hll AS HyperLogLog) END)
               ) AS mau_30d
FROM iceberg.analytics.daily_user_hll
WHERE event_date >= CURRENT_DATE - INTERVAL '29' DAY;
```

## Accuracy Trade-offs

HyperLogLog has approximately **2.3% relative standard error** by default:
- 68% of estimates within ±2.3% of the true count
- 95% within ±4.6%

For internal ops dashboards, 2% error is invisible. For customer-facing billing or compliance, use exact `COUNT(DISTINCT)` in a nightly batch job.

**Validate before committing:**
```sql
SELECT
    COUNT(DISTINCT user_id)  AS exact_count,
    approx_distinct(user_id) AS approx_count,
    ROUND(100.0 * (approx_distinct(user_id) - COUNT(DISTINCT user_id))
          / COUNT(DISTINCT user_id), 3) AS pct_error
FROM iceberg.analytics.events
WHERE event_date = DATE '2026-05-26';
```

Run on 5–10 different days. If error stays under ~1.5%, sketches are safe for your use case.

## Nightly Sketch Refresh

```sql
-- After the main events table is loaded, schedule this to run:
INSERT INTO iceberg.analytics.daily_user_hll
SELECT
    event_date,
    CAST(approx_set(user_id) AS varbinary) AS user_id_hll
FROM iceberg.analytics.events
WHERE event_date = CURRENT_DATE - INTERVAL '1' DAY
GROUP BY event_date;
```

The sketch table stays tiny — one row per day, a few KB each. For a year of data: ~365 rows, ~1 MB total.
