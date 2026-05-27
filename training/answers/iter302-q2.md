# Answer to Q2: COUNT(DISTINCT) Performance on 500M Rows

## Why it's slow — the fundamental problem

`COUNT(DISTINCT user_id)` grouped by day over 500M rows hits a fundamental distributed systems constraint: Trino cannot count distinct values in parallel across workers. Here's the execution:

1. **Each worker reads its partition** (partition pruning helps — 12-month query reads 365 day-partitions).
2. **All `user_id` values shuffle to a single coordinator node** — every unique ID from every partition must land on one place to detect duplicates.
3. **One node holds all distinct values in memory** to build the deduplication set.

For 12 months vs 30 days, you're shuffling roughly 12x more data and holding 12x more IDs in memory. At 500M rows with millions of distinct users, memory pressure on that single node is the bottleneck. This is not a bug in your query or Trino — it's how exact distinct counts work in all distributed systems.

## Solution 1: `approx_distinct()` — 10–50x faster with ~2% error

Trino's `approx_distinct()` uses the **HyperLogLog** probabilistic sketch algorithm. Instead of storing actual values, it maintains a compact data structure that approximates the distinct count.

```sql
-- Slow (exact):
SELECT event_date, COUNT(DISTINCT user_id) AS dau
FROM iceberg.analytics.events
WHERE event_date >= DATE '2025-05-27'
GROUP BY event_date;

-- Fast (approximate, ~2% error):
SELECT event_date, approx_distinct(user_id) AS dau
FROM iceberg.analytics.events
WHERE event_date >= DATE '2025-05-27'
GROUP BY event_date;
```

**What "~2% error" actually means:**
- 68% of estimates are within ±2.3% of the true value
- 95% of estimates are within ±4.6%
- It is NOT a hard ceiling — some estimates can be off by more

In practice on typical SaaS cohort sizes (10K–10M users), HyperLogLog stays well within 2% because the algorithm works best on large sets. On very small cohorts (hundreds of users), error can be larger.

**Tighten accuracy with the second parameter:**
```sql
-- 1% target error (higher memory, but still far cheaper than exact)
SELECT event_date, approx_distinct(user_id, 0.01) AS dau
FROM events
WHERE event_date >= DATE '2025-05-27'
GROUP BY event_date;
-- Default error is 0.023 (2.3%); range is 0.0040 – 0.26
```

**Validate on your real data before deploying:**
```sql
SELECT
    COUNT(DISTINCT user_id)  AS exact_count,
    approx_distinct(user_id) AS approx_count,
    ROUND(100.0 * (approx_distinct(user_id) - COUNT(DISTINCT user_id))
          / COUNT(DISTINCT user_id), 3) AS pct_error
FROM iceberg.analytics.events
WHERE event_date = DATE '2026-05-15';
```

Run this on 5–10 different days. If all samples stay under ~1.5% error, `approx_distinct` is safe for your workload.

## Is it trustworthy enough for customers?

**Depends on the use case:**

| Situation | Recommendation |
|---|---|
| Internal/ops dashboards — trend matters, not exact value | `approx_distinct()` — fine |
| Customer dashboards showing "your active users" as a trend | `approx_distinct()` with validation — usually acceptable |
| Revenue/billing (seats, per-active-user pricing) | Exact `COUNT(DISTINCT)` — a 2% error is money |
| Compliance reports | Exact — run as overnight batch jobs |

The key concern for customer-facing numbers is non-determinism: the same `approx_distinct` query can return slightly different numbers on different runs. If customers can see numbers change slightly between page loads, consider using a pre-aggregated rollup table (Solution 2) for historical data.

## Solution 2: Pre-aggregated daily rollup table (production pattern)

Build a small summary table once per night, then dashboards query the rollup instead of raw events:

```sql
-- Build nightly via dbt model or Spark job:
CREATE TABLE iceberg.analytics.daily_active_users AS
SELECT
    event_date,
    tenant_id,
    COUNT(DISTINCT user_id) AS dau
FROM iceberg.analytics.events
WHERE event_date >= DATE '2025-01-01'
GROUP BY event_date, tenant_id;
```

```sql
-- Customer dashboard query (365 rows → milliseconds):
SELECT event_date, dau
FROM iceberg.analytics.daily_active_users
WHERE event_date >= CURRENT_DATE - INTERVAL '365' DAY
  AND tenant_id = 'acme'
ORDER BY event_date;
```

**Why this is the production pattern:**
- Expensive `COUNT(DISTINCT)` runs once per night when the cluster is idle
- All dashboards hit a 365-row table — no shuffle, no memory pressure
- Numbers are deterministic and repeatable
- 24-hour staleness is the only trade-off

**For today's numbers (real-time):** Use `approx_distinct()` for the current incomplete day, then UNION with yesterday's rollup:

```sql
SELECT event_date, dau FROM daily_active_users
WHERE event_date >= CURRENT_DATE - INTERVAL '365' DAY
  AND event_date < CURRENT_DATE
UNION ALL
SELECT CURRENT_DATE, approx_distinct(user_id)
FROM events
WHERE event_date = CURRENT_DATE;
```

## Before anything else: verify partition pruning is working

First check that your 12-month query is actually using partition pruning. Without it, you're scanning 500M rows regardless.

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT event_date, COUNT(DISTINCT user_id)
FROM iceberg.analytics.events
WHERE event_date >= DATE '2025-05-27'
GROUP BY event_date;
```

Look for `TableScan` with a `partitions` count in the output. If it shows all partitions being scanned despite the date filter, your table may not be partitioned by `event_date` — that's the first fix.

Also run ANALYZE to give the CBO accurate statistics:
```sql
ANALYZE iceberg.analytics.events
  WITH (columns = ARRAY['user_id', 'event_date', 'tenant_id']);
```

## Recommended approach for your stack

1. **Internal dashboards:** Switch to `approx_distinct()` now. Validate accuracy on your data first.

2. **Customer-facing "active users" trend:** Build the nightly rollup table. Use `approx_distinct()` for today-so-far. Deploy both, union at query time.

3. **Billing/compliance:** Keep exact `COUNT(DISTINCT)`, but run as batch jobs at night rather than in the dashboarding path.

4. **If exact queries still time out:** Break into monthly sub-queries and UNION them, or add narrower date ranges. Each monthly chunk fits in worker memory; the 12-month all-at-once doesn't.

The 3–4 minute query time you're seeing is expected for an exact `COUNT(DISTINCT)` over 12 months at 500M rows. `approx_distinct()` or a nightly rollup table will bring that to under 1 second.
