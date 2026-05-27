# Answer to Q1: approx_percentile for p99 Latency Dashboards (Iter 307)

## What approx_percentile Actually Does

`approx_percentile` uses the **T-Digest algorithm** — a probabilistic sketch that compresses a large dataset into a fixed-size summary. Instead of storing every value and sorting them (which costs memory and CPU), T-Digest builds a compact binary sketch as it processes rows, then extracts percentile estimates from that sketch. It's accurate in the tails of the distribution (p95, p99) and very accurate in the middle (p50).

## Multi-Percentile in a Single Query

You do NOT need to run three separate queries. Trino accepts an ARRAY of percentile values:

```sql
-- Three separate columns (most dashboard tools prefer this):
SELECT
  approx_percentile(latency_ms, 0.50) AS p50,
  approx_percentile(latency_ms, 0.95) AS p95,
  approx_percentile(latency_ms, 0.99) AS p99
FROM iceberg.analytics.api_logs
WHERE event_date = CURRENT_DATE;
```

```sql
-- Or as a single ARRAY column (one pass, one row returned):
SELECT
  approx_percentile(latency_ms, ARRAY[0.50, 0.95, 0.99]) AS percentiles
FROM iceberg.analytics.api_logs
WHERE event_date = CURRENT_DATE;
-- Returns: [120, 340, 890] → p50=120ms, p95=340ms, p99=890ms
```

Both forms scan the data exactly once. Use the first form when your dashboard tool expects named columns; use the second for programmatic consumers.

**Important Trino syntax note:** Trino does NOT support `PERCENTILE_CONT(...) WITHIN GROUP (ORDER BY ...)` (that's Postgres/Snowflake syntax). Always use `approx_percentile(column, fraction)` in Trino. Use `0.5` for median, `0.95` for p95, `0.99` for p99.

## When Approximate Is Safe vs When You Need Exact

The decision is about the **consequences of being off by a few percent** — not the size of your dataset.

**Use `approx_percentile` when:**
- Building **internal dashboards, monitoring, and ops reviews** — engineering teams won't notice 1–2% error
- Charting **trends over time** — the shape of the curve matters more than the exact y-value on any day
- The query **refreshes frequently** (every minute or on page load) and latency matters
- The metric is used for **capacity planning or alerting thresholds** — rough accuracy is fine

**Use exact percentile when:**
- The number is **customer-facing** and tied to an SLA commitment (e.g., "your p99 is 250ms per contract")
- The metric affects **billing, compliance, or audit reports** where auditors may verify the numbers
- The value drives **contractual penalties** if incorrect

**The clearest rule:** "Would the business be harmed if this number was 2% off?" If yes, use exact. If no, use approximate.

For an internal p99 API latency dashboard — `approx_percentile` is almost certainly safe. The time savings (10x–50x faster on large datasets) is significant.

## Accuracy Model

T-Digest has no hard error ceiling — the "~2% error" is a **relative standard deviation**:
- ~68% of estimates fall within ±2% of the true value
- ~95% fall within ±4%
- ~99.7% fall within ±6%

This means: if your true p99 is 500ms, your approx_percentile estimate is almost always between 490ms and 510ms, and essentially always between 480ms and 520ms. For monitoring and dashboards, this variation is invisible.

Edge case: very small datasets (<1,000 rows in the time window) widen the relative error. If a particular tenant had only 50 API calls yesterday, the p99 estimate on those 50 calls may be less reliable. Consider exact percentile for small-sample cohorts.

## Validate on Your Data Before Committing

Run this on a historical day where you have a large enough sample to compare visually against your existing monitoring (e.g., Datadog or your app server logs):

```sql
-- Compute multiple percentiles in one query across days:
SELECT
  event_date,
  COUNT(*) AS request_count,
  approx_percentile(latency_ms, 0.50)  AS p50,
  approx_percentile(latency_ms, 0.95)  AS p95,
  approx_percentile(latency_ms, 0.99)  AS p99,
  MAX(latency_ms)                       AS p100_exact
FROM iceberg.analytics.api_logs
WHERE event_date >= CURRENT_DATE - INTERVAL '7' DAY
GROUP BY event_date
ORDER BY event_date;
```

Compare p99 against your existing monitoring system. If numbers are within 2–3% of what you'd expect, you're safe for dashboard use.

## Performance Comparison

| Function | 1M rows | 100M rows | Notes |
|---|---|---|---|
| `approx_percentile(col, 0.99)` | ~200ms | ~2s | No sort, fixed memory per executor |
| Exact percentile (via sort) | ~1s | ~30–120s | Full sort across all rows |
| `approx_percentile(col, ARRAY[...])` | ~200ms | ~2s | Same cost as single percentile |

At 100M rows (typical event table for a mid-size SaaS), the difference is the gap between a responsive dashboard and a timeout.

## Production Dashboard Query

```sql
-- p50/p95/p99 per endpoint for today, grouped by hour:
SELECT
  date_trunc('hour', occurred_at) AS hour,
  endpoint,
  COUNT(*)                                    AS request_count,
  approx_percentile(latency_ms, 0.50)         AS p50_ms,
  approx_percentile(latency_ms, 0.95)         AS p95_ms,
  approx_percentile(latency_ms, 0.99)         AS p99_ms
FROM iceberg.analytics.api_logs
WHERE event_date = CURRENT_DATE
GROUP BY 1, 2
ORDER BY 1, 2;
```

This runs on Iceberg+Trino, only scans today's partition (one day's files), and returns latency breakdowns across all endpoints in a single query — no subqueries, no joins, no separate queries per percentile.
