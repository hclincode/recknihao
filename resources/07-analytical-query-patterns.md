# Common Analytical Query Patterns

> **Production note:** All SQL examples below run on Trino against Iceberg tables in MinIO. Trino syntax is standard ANSI SQL with a few extras (`date_trunc`, `unnest`, window functions) that are well documented.

---

## Quick answer

Four patterns cover ~90% of SaaS analytics:

1. **Aggregations** — "how many X by Y" (signups by plan, revenue by month). `COUNT`, `SUM`, `GROUP BY`.
2. **Funnels** — "what % of users moved from step A to step B to step C." Sequence of events with drop-off at each step.
3. **Cohort analysis** — "of users who signed up in week 0, how many were still active in week 4." Group by join date, measure retention over time.
4. **Time-series** — "show me signups per day for the last 30 days, with zeros on days no one signed up." Bucket by time + fill gaps.

Each pattern stresses an OLAP engine differently — knowing which is which helps you debug slow queries.

---

## 1. Aggregations (the bread and butter)

**The SaaS question:** "How many signups did we get this month, broken down by plan?"

```sql
SELECT plan_type, COUNT(*) AS signups
FROM iceberg.analytics.user_events
WHERE event_name = 'signup'
  AND event_date >= date_trunc('month', current_date)
GROUP BY plan_type
ORDER BY signups DESC;
```

**Why it's slow on Postgres, fast on Trino + Iceberg:**
- Postgres reads every row of `user_events`, including columns it doesn't need (row-oriented storage).
- Trino reads only `plan_type`, `event_name`, and `event_date` columns from the Parquet files. Iceberg skips files that don't fall in the current month.

**What to watch for:** if `GROUP BY` has high cardinality (e.g., `GROUP BY user_id` across 50M users), the engine has to keep all distinct groups in memory. Add a `HAVING COUNT(*) > N` to trim, or pre-aggregate.

---

## 2. Funnels (drop-off across a sequence of events)

**The SaaS question:** "Of users who signed up last week, how many completed onboarding, and of those, how many activated a paid feature within 7 days?"

A note on the `WITH ... AS (...)` blocks below: these are **CTEs** (Common Table Expressions — named, inline temporary result sets that you can reference later in the same query, similar to declaring a variable). They make multi-step queries readable without creating real tables.

```sql
WITH signups AS (
  SELECT user_id, MIN(event_time) AS signed_up_at
  FROM iceberg.analytics.user_events
  WHERE event_name = 'signup'
    AND event_date >= current_date - INTERVAL '14' DAY
  GROUP BY user_id
),
onboarded AS (
  SELECT s.user_id
  FROM signups s
  JOIN iceberg.analytics.user_events e
    ON e.user_id = s.user_id
   AND e.event_name = 'onboarding_complete'
   AND e.event_time BETWEEN s.signed_up_at AND s.signed_up_at + INTERVAL '7' DAY
),
activated AS (
  SELECT o.user_id
  FROM onboarded o
  JOIN iceberg.analytics.user_events e
    ON e.user_id = o.user_id
   AND e.event_name = 'paid_feature_used'
   AND e.event_time <= (SELECT signed_up_at FROM signups WHERE user_id = o.user_id) + INTERVAL '7' DAY
)
SELECT
  (SELECT COUNT(*) FROM signups)   AS step1_signups,
  (SELECT COUNT(*) FROM onboarded) AS step2_onboarded,
  (SELECT COUNT(*) FROM activated) AS step3_activated;
```

**Why funnels are hard:** each step is a separate scan of `user_events`. A 3-step funnel scans the table 3 times. This is exactly the work columnar storage + Iceberg partition pruning makes survivable — same query on Postgres would melt the DB.

### Single-pass funnel with `MATCH_RECOGNIZE`

When the CTE/JOIN funnel above gets slow (8+ minutes on hundreds of millions of rows) or you find yourself writing 5-step funnels with cascading JOINs, switch to `MATCH_RECOGNIZE`. It's a SQL-standard clause Trino supports that lets you describe an **ordered pattern of rows** — like a regex over event sequences — so Trino can match the whole funnel in a single pass per user instead of N joins.

Here's the same signup → activation → payment (within 7 days) funnel as a single MATCH_RECOGNIZE query:

```sql
SELECT user_id, funnel_start, funnel_end
FROM iceberg.analytics.user_events
MATCH_RECOGNIZE (
  PARTITION BY user_id
  ORDER BY event_time
  MEASURES
    FIRST(event_time) AS funnel_start,
    LAST(event_time)  AS funnel_end
  ONE ROW PER MATCH
  AFTER MATCH SKIP TO NEXT ROW
  PATTERN (signup activation+ payment+)
  DEFINE
    signup     AS event_name = 'signup',
    activation AS event_name = 'activation'
                  AND event_time <= FIRST(event_time) + INTERVAL '7' DAY,
    payment    AS event_name = 'payment'
                  AND event_time <= FIRST(event_time) + INTERVAL '7' DAY
);
```

How to read this:
- `PARTITION BY user_id ORDER BY event_time` — treat the table as one ordered timeline per user.
- `PATTERN (signup activation+ payment+)` — match a row labeled `signup`, then one or more `activation`, then one or more `payment`, in that order.
- `DEFINE` — what makes a row qualify as each label. The `event_time <= FIRST(event_time) + INTERVAL '7' DAY` check is the 7-day window.
- `MEASURES` — what to return per matched user (here: when they entered and exited the funnel).
- `ONE ROW PER MATCH` — return one row per user who completed the full funnel.

To get the funnel **counts** (step1/step2/step3 conversions like the CTE version above), you'd run two queries — one MATCH_RECOGNIZE for completion to step 2, one for completion to step 3 — or wrap this in a CTE and combine with the original signup count.

**When to use MATCH_RECOGNIZE vs the CTE/JOIN approach:**

| Use MATCH_RECOGNIZE when... | Use CTE/JOIN when... |
|---|---|
| Funnel has 4+ steps and the CTE version is hard to read. | 2–3 step funnels where the CTE version is fine and more debuggable. |
| Performance matters — single pass per user is much faster than N table scans. | You're prototyping and want to add/remove steps quickly. |
| The events must occur **in a strict order** (signup *then* activation *then* payment). | Order doesn't matter as much, or you need fuzzy logic (e.g., "completed any 2 of 4 steps"). |
| You need windowed events (within 7 days of start). | You're targeting portability — MATCH_RECOGNIZE is supported in Trino, Snowflake, Oracle, but not Postgres, MySQL, BigQuery, or DuckDB. |

Start with the CTE/JOIN version because it's easier to debug. Migrate to MATCH_RECOGNIZE only when the CTE version is too slow or too tangled.

---

## 3. Cohort analysis (retention over time)

**The SaaS question:** "Of users who signed up in the week of Jan 1, how many were active in week 0, week 1, week 2, week 3?"

The mental model is a triangular table:

| signup_week | week_0 | week_1 | week_2 | week_3 |
|---|---|---|---|---|
| 2026-01-01 | 1,000 | 620 | 480 | 410 |
| 2026-01-08 | 1,200 | 750 | 590 | — |
| 2026-01-15 | 980 | 610 | — | — |
| 2026-01-22 | 1,100 | — | — | — |

Conceptually:

```sql
WITH cohorts AS (
  SELECT user_id,
         date_trunc('week', MIN(event_time)) AS cohort_week
  FROM iceberg.analytics.user_events
  WHERE event_name = 'signup'
  GROUP BY user_id
),
activity AS (
  SELECT c.cohort_week,
         date_diff('week', c.cohort_week, e.event_time) AS week_offset,
         COUNT(DISTINCT e.user_id) AS active_users
  FROM cohorts c
  JOIN iceberg.analytics.user_events e ON e.user_id = c.user_id
  GROUP BY c.cohort_week, date_diff('week', c.cohort_week, e.event_time)
)
SELECT * FROM activity ORDER BY cohort_week, week_offset;
```

**Why this stresses OLAP:** the GROUP BY has two dimensions and `COUNT(DISTINCT user_id)` is memory-hungry. The bottleneck is **not** "all values get sent to one coordinator node" — Trino distributes distinct aggregation across workers. The real costs are (1) an **extra shuffle pass** per distinct column on top of the GROUP BY shuffle (Trino's MarkDistinct strategy partitions by `(group_key, distinct_col)` so duplicates can be resolved per partition), and (2) **per-group memory pressure** — each worker holds a hash set of distinct values for every group it's responsible for. A 26-week × 1M-distinct-user cohort forces each worker to keep thousands of large hash sets in memory simultaneously.

For large cohorts use `approx_distinct(user_id)` in Trino — a built-in function that returns an *approximate* distinct count using the **HyperLogLog** algorithm (a probabilistic data structure that estimates cardinality from a tiny fixed-size sketch instead of storing every value seen): **2.3% standard error** (per Trino docs), 100x less memory, and only one cheap merge shuffle instead of MarkDistinct's per-column re-shuffle.

**Before giving up exactness, try changing the distinct-aggregation strategy.** Trino exposes a session knob that controls how distinct aggregation is planned:

```sql
SET SESSION distinct_aggregations_strategy = 'pre_aggregate';
-- other values: 'mark_distinct' (default), 'single_step', 'split_to_subqueries', 'automatic'
```

`pre_aggregate` adds a per-worker partial-deduplication step before the final shuffle and often outperforms `mark_distinct` for queries with multiple distinct columns. `split_to_subqueries` rewrites each `COUNT(DISTINCT ...)` into its own subquery joined back together — best when you have many distinct expressions in one query. Try each strategy with `EXPLAIN ANALYZE` and compare actual CPU/wall time before deciding to approximate.

### `approx_distinct` vs `COUNT(DISTINCT)` — when to use each

The **2.3% standard error** for `approx_distinct` is worth understanding precisely before you put it on a customer-facing dashboard.

**The 2.3% is a standard deviation (σ), not a hard ceiling.** HyperLogLog's error is described as a *relative standard error* — meaning roughly 68% of estimates fall within ±2.3% of the true count, 95% fall within ±4.6%, and 99.7% fall within ±6.9%. It is **not** a guarantee that no answer will ever be off by more than 2.3%. In practice, however, for typical SaaS cohort sizes (1K–10M distinct users) the real-world error stays well within 2% the vast majority of the time — HyperLogLog is most accurate in exactly this range. The bad surprises happen when you (a) report a single number to a customer who's reconciling it against the in-app counter, or (b) use it on tiny cohorts (<1K) where the relative error widens.

**Decision rule:**

| Use `COUNT(DISTINCT)` when... | Use `approx_distinct` when... |
|---|---|
| Cohort is < 1M users (the exact count is fast enough — no memory pressure on Trino). | Cohort is > 10M users and the exact query is timing out or hitting `query_max_memory` limits. |
| The number is **customer-facing** and must match the app exactly (e.g., "your team had 42 active users this week" shown in the customer's dashboard, where they can count them by hand). | The number is **internal/operational** — engineering dashboards, capacity planning, weekly ops review — where 2.3% error is invisible and acceptable. |
| The metric drives **revenue or billing** (seat counts, per-active-user pricing, usage-based invoices). A 2.3% error here is a real money bug and a support-ticket generator. | You're charting trends over time — the shape of the curve matters more than the exact y-value on any one day. |

**Validation recipe — run this once before committing to either approach.** Don't take the "2%" claim on faith for your specific data shape; measure it:

```sql
-- Pick one recent partition (a single day works) and run both counts.
WITH sample AS (
  SELECT user_id
  FROM iceberg.analytics.user_events
  WHERE event_date = DATE '2026-05-15'
)
SELECT
  COUNT(DISTINCT user_id)        AS exact_count,
  approx_distinct(user_id)       AS approx_count,
  ROUND(
    100.0 * (approx_distinct(user_id) - COUNT(DISTINCT user_id))
    / COUNT(DISTINCT user_id),
    3
  ) AS pct_error
FROM sample;
```

Run this on 5–10 different partitions covering your typical query shapes (per-tenant slices, per-day slices, per-cohort slices). If `pct_error` stays under ~1% across all of them, `approx_distinct` is safe for that workload. If you see any sample over 3%, do **not** use it for customer-facing numbers without further sampling — your data shape may have characteristics (heavy skew, very small cohorts, unusual cardinality patterns) that push HyperLogLog past its sweet spot.

**One more nuance:** `approx_distinct` is non-deterministic in the sense that the same query *can* return a slightly different number on a different cluster version or after data reorganization (compaction, partition rewrites). For customer-facing numbers, determinism matters — customers notice if their "active users" jumps from 9,847 to 9,851 between two page loads. That alone is often enough reason to prefer exact `COUNT(DISTINCT)` for anything a customer sees.

### Pre-aggregated HLL sketches: the rolling-window production pattern

For DAU/WAU/MAU dashboards that need to refresh every minute against a 500M-row events table, even `approx_distinct` is wasteful if it re-scans raw events on every refresh. The production pattern is to **build a daily HyperLogLog sketch table once**, then merge sketches at query time for any window size you want.

```sql
-- Step 1: nightly job — one row per day, one sketch column.
-- approx_set(col) builds an HLL sketch (a few KB binary blob) for a column.
-- IMPORTANT: cast the sketch to varbinary before storing — Iceberg's Parquet
-- storage does not natively know about Trino's HyperLogLog type, so you must
-- serialize the sketch to binary. The on-disk column type is varbinary.
CREATE TABLE iceberg.analytics.daily_user_hll
WITH (partitioning = ARRAY['event_date'])
AS SELECT
    event_date,
    CAST(approx_set(user_id) AS varbinary) AS user_id_hll
FROM iceberg.analytics.events
GROUP BY event_date;

-- Step 2: compute rolling 7-day WAU without re-scanning raw events.
-- IMPORTANT: cast the stored varbinary back to HyperLogLog before calling
-- merge() — merge() and cardinality() only accept the HyperLogLog type.
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

**Why the casts?** Trino's `HyperLogLog` is an in-engine type — the Iceberg connector (and Parquet/ORC under it) has no native encoding for it. The standard pattern from the [official Trino HyperLogLog docs](https://trino.io/docs/current/functions/hyperloglog.html) is: **serialize to `varbinary` on the write side, deserialize back to `HyperLogLog` on the read side.** If you forget the write-side cast, the CTAS/INSERT fails with a type error like `Unsupported type: HyperLogLog`. If you forget the read-side cast, `merge()` fails with `Unexpected parameters (varbinary) for function merge`.

The three primitives:
- `approx_set(column)` — builds a HyperLogLog sketch for a column. Returns the `HyperLogLog` type (not a `BIGINT`). Cast to `varbinary` to persist.
- `merge(hll_column)` — aggregate function that unions multiple sketches into one. Input must be `HyperLogLog`, not `varbinary` — cast first when reading from a stored sketch table. Merging sketches and then taking cardinality is mathematically equivalent to running `approx_distinct` over the union of all underlying rows — that is the *whole point* of HLL: sketches compose.
- `cardinality(hll)` — extracts the approximate distinct count from a (merged) sketch.

Pay the sketch-building cost once per day. Every subsequent rolling-window query reads at most a few dozen tiny rows from the sketch table — no scan of the raw 500M-row events table. This pattern also works for arbitrary windows ("last 30 days", "last 90 days", "this calendar month") without rebuilding anything: same sketch table, different join range. It is the standard solution for rolling cardinality in Trino, Snowflake, BigQuery, and DuckDB.

**Verify your rewrite paid off with `EXPLAIN ANALYZE`.** When you replace `COUNT(DISTINCT)` with `approx_distinct`, or replace a raw-events scan with a sketch-table merge, prove it actually reduced I/O — don't take it on faith. Run both versions wrapped in `EXPLAIN ANALYZE` (which actually executes the query and reports real bytes scanned, actual rows per stage, and wall time per stage). Compare the "Input" bytes line — if the rewrite didn't reduce bytes scanned, the optimization didn't land (most often: the rollup/sketch table wasn't picked because of a planner mismatch, or the partition filter wasn't pushed down). Plain `EXPLAIN` only shows the *estimated* cost; `EXPLAIN ANALYZE` shows the *actual* cost.

### Milestone-retention variant: % came back in 7 / 30 / 90 days

The weekly-offset matrix above counts how many users were active in each week. A complementary question is: "of users who first showed up in a given week, what % came back within 7, 30, or 90 days?" This collapses the matrix into three boolean columns — did the user return at all within each window?

```sql
WITH first_events AS (
  SELECT user_id,
         date_trunc('week', MIN(event_time)) AS cohort_week,
         MIN(event_time)                     AS first_event_at
  FROM iceberg.analytics.user_events
  GROUP BY user_id
),
cohort_sizes AS (
  SELECT cohort_week, COUNT(DISTINCT user_id) AS total_users
  FROM first_events
  GROUP BY cohort_week
),
returns AS (
  SELECT
    f.cohort_week,
    -- COUNT(DISTINCT CASE WHEN ...) counts each user once even if they returned multiple times
    COUNT(DISTINCT CASE WHEN date_diff('day', f.first_event_at, e.event_time) BETWEEN 1 AND 7  THEN e.user_id END) AS returned_7d,
    COUNT(DISTINCT CASE WHEN date_diff('day', f.first_event_at, e.event_time) BETWEEN 1 AND 30 THEN e.user_id END) AS returned_30d,
    COUNT(DISTINCT CASE WHEN date_diff('day', f.first_event_at, e.event_time) BETWEEN 1 AND 90 THEN e.user_id END) AS returned_90d
  FROM first_events f
  JOIN iceberg.analytics.user_events e ON e.user_id = f.user_id
  GROUP BY f.cohort_week
)
SELECT c.cohort_week,
       c.total_users,
       ROUND(100.0 * r.returned_7d  / c.total_users, 1) AS pct_retained_7d,
       ROUND(100.0 * r.returned_30d / c.total_users, 1) AS pct_retained_30d,
       ROUND(100.0 * r.returned_90d / c.total_users, 1) AS pct_retained_90d
FROM cohort_sizes c
JOIN returns r ON r.cohort_week = c.cohort_week
WHERE date_diff('day', c.cohort_week, current_date) >= 90  -- only cohorts old enough to measure
ORDER BY c.cohort_week DESC;
```

**The critical idiom:** use `COUNT(DISTINCT CASE WHEN ... THEN user_id END)`, **not** `SUM(CASE WHEN ... THEN 1 ELSE 0 END)`.

The SUM form counts *event rows*, not users. If a user fires 5 events in the 7-day window, they contribute 5 to `returned_7d` and 1 to `total_users`. That produces retention percentages above 100% on any active cohort — the query passes silently and the numbers look nonsensical.

`COUNT(DISTINCT CASE WHEN ... THEN user_id END)` counts each user_id at most once per window, regardless of how many events they fired. Trino supports `NULL` in DISTINCT aggregates — when the CASE does not match, it returns `NULL`, which COUNT(DISTINCT) ignores.

**Incomplete-cohort filter:** `date_diff('day', c.cohort_week, current_date) >= 90` is mandatory. A cohort from last week cannot have 90-day retention yet — without this filter, young cohorts show artificially low percentages and make retention look like it's falling.

**Overlapping vs non-overlapping buckets:** `BETWEEN 1 AND 7`, `BETWEEN 1 AND 30`, `BETWEEN 1 AND 90` are overlapping — a user who returns in 5 days counts as retained in all three windows. This matches industry convention (cumulative retention). If you want non-overlapping buckets (1–7, 8–30, 31–90), change the BETWEEN ranges accordingly.

**Date-vs-timestamp precision:** `date_diff('day', first_event_at, event_time)` between two *timestamps* measures elapsed whole days from the timestamp components. A user who fired their first event at 23:00 and returned at 01:00 the next day produces `date_diff = 0`. To measure calendar-day differences (more intuitive for daily retention windows), cast both sides to `date`: `date_diff('day', date(first_event_at), date(event_time))`.

### Wide-pivot variant: percentage retention as columns

The query above returns the cohort grid in **long format** (one row per cohort_week × week_offset). That's fine for some BI tools, but stakeholders usually want the **wide format** with one column per week, showing percentage retention (week_N / week_0 × 100). Pivot it with `CASE WHEN` and divide by the cohort size:

```sql
WITH cohorts AS (
  SELECT user_id,
         date_trunc('week', MIN(event_time)) AS cohort_week
  FROM iceberg.analytics.user_events
  WHERE event_name = 'signup'
  GROUP BY user_id
),
activity AS (
  SELECT c.cohort_week,
         date_diff('week', c.cohort_week, e.event_time) AS week_offset,
         COUNT(DISTINCT e.user_id) AS active_users
  FROM cohorts c
  JOIN iceberg.analytics.user_events e ON e.user_id = c.user_id
  WHERE date_diff('week', c.cohort_week, e.event_time) BETWEEN 0 AND 4
  GROUP BY c.cohort_week, date_diff('week', c.cohort_week, e.event_time)
),
pivoted AS (
  SELECT cohort_week,
         SUM(CASE WHEN week_offset = 0 THEN active_users END) AS week_0,
         SUM(CASE WHEN week_offset = 1 THEN active_users END) AS week_1,
         SUM(CASE WHEN week_offset = 2 THEN active_users END) AS week_2,
         SUM(CASE WHEN week_offset = 3 THEN active_users END) AS week_3,
         SUM(CASE WHEN week_offset = 4 THEN active_users END) AS week_4
  FROM activity
  GROUP BY cohort_week
)
SELECT cohort_week,
       week_0,
       ROUND(100.0 * week_1 / week_0, 1) AS pct_week_1,
       ROUND(100.0 * week_2 / week_0, 1) AS pct_week_2,
       ROUND(100.0 * week_3 / week_0, 1) AS pct_week_3,
       ROUND(100.0 * week_4 / week_0, 1) AS pct_week_4
FROM pivoted
ORDER BY cohort_week;
```

This produces the familiar triangular retention table — `week_0` is always 100%, and later columns show the percentage of the cohort still active.

**Tip:** Let your BI tool pivot if it supports it — most dashboards (Superset, Metabase) can pivot from the long format natively, so you can keep the simpler SQL and let the dashboard build the wide view. Only pivot in SQL when you're exporting to a flat file or when the BI tool can't do it.

---

## 4. Time-series rollups (with gap-filling)

**The SaaS question:** "Show me signups per day for the last 30 days."

Naive version:

```sql
SELECT date_trunc('day', event_time) AS day, COUNT(*) AS signups
FROM iceberg.analytics.user_events
WHERE event_name = 'signup'
  AND event_time >= current_date - INTERVAL '30' DAY
GROUP BY 1
ORDER BY 1;
```

**The gotcha:** if no one signed up on Jan 14, that day is *missing from the result* — not zero. Dashboards then show a deceiving line that "skips" days.

**Fix: generate a calendar and LEFT JOIN.**

```sql
WITH calendar AS (
  SELECT date_add('day', n, current_date - INTERVAL '30' DAY) AS day
  FROM UNNEST(sequence(0, 29)) AS t(n)
),
signups AS (
  SELECT date_trunc('day', event_time) AS day, COUNT(*) AS cnt
  FROM iceberg.analytics.user_events
  WHERE event_name = 'signup' AND event_time >= current_date - INTERVAL '30' DAY
  GROUP BY 1
)
SELECT c.day, COALESCE(s.cnt, 0) AS signups
FROM calendar c
LEFT JOIN signups s ON s.day = c.day
ORDER BY c.day;
```

`date_trunc('day' | 'week' | 'month', col)` is the Trino function you'll use constantly. It rounds a timestamp down to the start of a bucket.

---

## 5. Window functions (running totals, ranks, lag/lead)

**The SaaS question family:** "Running total of revenue per tenant by day." "Each customer's day-over-day change in MRR." "Top 10 highest-value orders per tenant."

Window functions compute an aggregate or rank **per row** while still returning every input row — unlike `GROUP BY`, which collapses rows. Trino supports the full ANSI SQL window function syntax (documented at https://trino.io/docs/current/functions/window.html).

The general shape:

```sql
<window_function>(<args>) OVER (
  PARTITION BY <columns>     -- buckets the window (per-tenant is typical for SaaS)
  ORDER BY <columns>         -- ordering within each bucket
  [<frame_clause>]           -- which rows in the bucket count for THIS row's result
)
```

### Pattern A: Running total (cumulative sum)

"Cumulative revenue per tenant over time."

```sql
SELECT
  day,
  tenant_id,
  amount,
  SUM(amount) OVER (
    PARTITION BY tenant_id
    ORDER BY day
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS cumulative_revenue
FROM iceberg.analytics.daily_revenue
WHERE day >= DATE '2026-01-01'
  AND tenant_id = 'acme'
ORDER BY day;
```

Why each piece matters:
- `PARTITION BY tenant_id` — every tenant gets its own running total. Without this, the cumulative sum would mix all tenants together. **Always partition by `tenant_id` for multi-tenant SaaS** so a tenant's window can't see another tenant's data.
- `ORDER BY day` — defines the order in which "previous rows" accumulate.
- `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` — the frame clause. "Sum every row from the start of the partition through this row." This is the canonical running-total frame.
- The `WHERE` clause executes BEFORE the window function, so partition pruning on `day` and `tenant_id` still works on the base scan. Window functions are not a barrier to file skipping — only to the final aggregation phase.

### Pattern B: Lag / Lead (compare to previous or next row)

"Day-over-day change in revenue per tenant."

```sql
SELECT
  day,
  tenant_id,
  revenue,
  LAG(revenue, 1) OVER (PARTITION BY tenant_id ORDER BY day) AS prev_day_revenue,
  revenue - LAG(revenue, 1) OVER (PARTITION BY tenant_id ORDER BY day) AS day_over_day_change
FROM iceberg.analytics.daily_revenue
WHERE day >= DATE '2026-01-01';
```

- `LAG(col, n)` returns the value of `col` from `n` rows back within the partition (default 1). Returns NULL when there is no prior row.
- `LEAD(col, n)` is the mirror — `n` rows forward.
- No frame clause needed — `LAG`/`LEAD` operate on a specific row offset, not a frame.

### Pattern C: Rank (top-N per group)

"Top 10 highest-value orders per tenant."

```sql
SELECT *
FROM (
  SELECT
    tenant_id,
    order_id,
    amount,
    RANK() OVER (PARTITION BY tenant_id ORDER BY amount DESC) AS revenue_rank
  FROM iceberg.analytics.orders
  WHERE order_date >= DATE '2026-01-01'
)
WHERE revenue_rank <= 10;
```

Rank function variants:
- `ROW_NUMBER()` — assigns a strictly increasing integer (1, 2, 3, 4) within the partition. Ties break arbitrarily.
- `RANK()` — ties get the same rank, then the next rank skips (1, 2, 2, 4).
- `DENSE_RANK()` — ties get the same rank, no gap (1, 2, 2, 3).
- `PERCENT_RANK()` — relative position as a fraction in `[0.0, 1.0]`. Formula: `(rank - 1) / (n - 1)` where `n` is partition row count. The top row gets `0.0`, the bottom row gets `1.0`. **Returns NULL when the partition has only one row** (divide-by-zero). Useful for "what percentile is this tenant in?" without computing a histogram.
- `NTILE(n)` — divides the partition into `n` roughly-equal buckets (quartiles=4, deciles=10, percentiles=100), returning the bucket number `1..n` for each row. **Remainder rows go to the EARLIEST buckets**: e.g., 10 rows with `NTILE(3)` → buckets are size 4/3/3, not 3/3/4. **The frame clause MUST be omitted** (Trino errors if you specify `ROWS BETWEEN ...` with `NTILE`).

Pick `ROW_NUMBER()` if you literally need "exactly 10 rows per tenant"; pick `RANK()`/`DENSE_RANK()` if you want to include all ties at rank 10.

### Pattern C2: `PERCENT_RANK` — "what percentile is this tenant in?"

"For each tenant, compute their relative position in the revenue distribution across the SaaS customer base."

```sql
SELECT
  tenant_id,
  total_revenue,
  PERCENT_RANK() OVER (ORDER BY total_revenue) AS revenue_percentile
FROM (
  SELECT tenant_id, SUM(amount) AS total_revenue
  FROM iceberg.analytics.orders
  WHERE order_date >= CURRENT_DATE - INTERVAL '90' DAY
  GROUP BY tenant_id
);
-- Returns one row per tenant with their percentile in [0.0, 1.0].
-- tenant with the lowest revenue: 0.0
-- tenant with the highest revenue: 1.0
-- median tenant: ~0.5
```

**When to pick `PERCENT_RANK` over computing percentiles directly:**
- You want a percentile **per row** (not just a few summary percentiles for the whole table). `PERCENT_RANK` returns the percentile of each individual row's value; `approx_percentile` returns only the value at a specified percentile.
- You're building a "your tenant is in the top X%" widget for a SaaS dashboard — one query, no second pass.
- The data set fits in a window-sort (a few million rows or fewer). For 500M+ rows where you only need summary percentiles (p50, p95, p99), use `approx_percentile` instead — sorting that many rows in a window is expensive.

**Edge case — single-row partition.** `PERCENT_RANK` returns NULL (the formula divides by `n - 1` which is 0). Guard with `COALESCE(PERCENT_RANK() OVER (...), 0.0)` if your downstream consumer can't handle NULLs.

**Sibling: `CUME_DIST` (cumulative distribution).** Trino also supports `CUME_DIST()` which returns `count_of_peers_or_lower / n` — slightly different math (the top row is `1.0`, not `(n-1)/n`). Use `PERCENT_RANK` for "fraction of rows STRICTLY below this one" and `CUME_DIST` for "fraction of rows AT OR BELOW this one."

### Pattern C3: `NTILE` — bucket rows into equal-size groups (quartiles, deciles, percentile buckets)

"Bucket each tenant into one of 10 deciles based on monthly active users so a dashboard can show 'top decile' / 'bottom decile' segments."

```sql
SELECT
  tenant_id,
  monthly_active_users,
  NTILE(10) OVER (ORDER BY monthly_active_users) AS mau_decile
FROM (
  SELECT tenant_id, COUNT(DISTINCT user_id) AS monthly_active_users
  FROM iceberg.analytics.feature_usage
  WHERE event_date >= CURRENT_DATE - INTERVAL '30' DAY
  GROUP BY tenant_id
);
-- Each tenant assigned a bucket 1..10.
-- Bucket 1 = lowest MAU tenants, Bucket 10 = highest MAU tenants.
```

**The remainder rule (this trips up engineers — read carefully).** `NTILE(n)` divides `rows_in_partition` by `n` and distributes the remainder `r` to the **first `r` buckets**, each of which gets one extra row.

| Rows in partition | `NTILE(4)` bucket sizes |
|---|---|
| 12 (12 ÷ 4 = 3, no remainder) | `3, 3, 3, 3` |
| 13 (13 ÷ 4 = 3 remainder 1) | `4, 3, 3, 3` — bucket 1 gets the extra row |
| 14 (14 ÷ 4 = 3 remainder 2) | `4, 4, 3, 3` — buckets 1 and 2 each get an extra |
| 15 (15 ÷ 4 = 3 remainder 3) | `4, 4, 4, 3` — buckets 1, 2, 3 each get an extra |

**This matters for SaaS metrics.** If you have 9,997 tenants and you compute `NTILE(10)` for "decile of revenue", the deciles are NOT all 999.7 rows each — they are `1000, 1000, 1000, 1000, 1000, 1000, 1000, 999, 999, 999` (first 7 buckets get the rounding-up). If a dashboard says "top decile = top 1000 tenants" and the real answer is "top decile = 999 tenants on this distribution", an audit may flag the off-by-one. State the rule explicitly in dashboard documentation, or use `PERCENT_RANK() >= 0.9` instead for an exact-cutoff threshold.

**The no-frame restriction.** Per the [Trino window functions docs](https://trino.io/docs/current/functions/window.html), `NTILE` **must not** be invoked with a window frame:

```sql
-- WRONG — Trino errors with "ntile cannot be used with a window frame".
SELECT NTILE(10) OVER (
  ORDER BY revenue
  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW   -- ILLEGAL with NTILE
) FROM customers;

-- CORRECT — omit the frame clause entirely.
SELECT NTILE(10) OVER (ORDER BY revenue) FROM customers;
```

This restriction applies to all the **ranking functions** in Trino (`ROW_NUMBER`, `RANK`, `DENSE_RANK`, `PERCENT_RANK`, `CUME_DIST`, `NTILE`) — frames are only meaningful for value-aggregating window functions like `SUM` / `AVG` / `LAG` / `LEAD`. Ranking functions operate over the entire partition by definition.

**When to pick `NTILE` over `PERCENT_RANK` or manual `CASE` bucketing:**

| Need | Use |
|---|---|
| Bucket every row into one of `N` named groups (deciles, quartiles, percentile bands) | `NTILE(N)` — concise, single window pass |
| Continuous percentile score per row (`0.0–1.0`) | `PERCENT_RANK()` — gives you the fraction, you decide the bucket boundaries |
| Custom (non-equal-size) buckets like "0-1k MAU", "1k-10k MAU", "10k+ MAU" | `CASE WHEN ... THEN ... END` over the column directly — `NTILE` only does equal-size bucketing |
| Exact "top 10% of tenants" — guaranteed cutoff regardless of count | `PERCENT_RANK() >= 0.9` filter — avoids the `NTILE` remainder-row off-by-one |

**NULL handling — filter NULLs out BEFORE the NTILE.** When the column you're bucketing on contains NULL values, NTILE doesn't skip them — it sorts them and assigns them to a bucket like any other value. Trino's **default NULL ordering is `NULLS LAST`** (regardless of `ASC` or `DESC`), per the [Trino SELECT docs](https://trino.io/docs/current/sql/select.html). So in `NTILE(10) OVER (ORDER BY revenue)` with some NULL revenues, the NULL rows land in the **highest deciles** (buckets 9 and 10) — which is almost certainly wrong for a "top decile = highest revenue" interpretation. Always filter NULLs explicitly:

```sql
-- WRONG — NULLs sort to the end (NULLS LAST default), landing in the top deciles.
SELECT
  tenant_id,
  monthly_revenue,
  NTILE(10) OVER (ORDER BY monthly_revenue) AS revenue_decile
FROM iceberg.analytics.tenant_revenue;
-- Result: tenants with NULL revenue get assigned to decile 9 or 10, polluting your "top 10%" answer.

-- CORRECT — pre-filter NULLs before the window function.
SELECT
  tenant_id,
  monthly_revenue,
  NTILE(10) OVER (ORDER BY monthly_revenue) AS revenue_decile
FROM iceberg.analytics.tenant_revenue
WHERE monthly_revenue IS NOT NULL;          -- explicit NULL filter
-- Alternative: keep NULLs in the result set but exclude them from the windowing.
-- The cleanest pattern is the WHERE filter above; Trino does NOT support `NTILE(...) OVER (... NULLS EXCLUDE)`.
```

If you can't drop the NULL rows (e.g., the result set needs all tenants present), bucket only the non-NULL rows via a subquery and `LEFT JOIN` the NULL rows back with `revenue_decile = NULL`. Do not rely on `NULLS FIRST` to "hide" them in bucket 1 — that just moves the bug.

### Pattern D: Sliding window (last 7 days rolling)

"7-day rolling average of daily active users per tenant."

```sql
SELECT
  day,
  tenant_id,
  dau,
  AVG(dau) OVER (
    PARTITION BY tenant_id
    ORDER BY day
    RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW
  ) AS rolling_7d_avg_dau
FROM iceberg.analytics.daily_dau;
```

- `RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW` — a **value-based** frame: include all rows whose `day` is within 6 days before this row. **Gap-day correct** — if a tenant has no events on `day = 2026-05-25` but has events on `2026-05-24` and `2026-05-26`, the frame for the `2026-05-26` row correctly includes the 5 days from `2026-05-20` through `2026-05-25` AND the 1 row from `2026-05-26`, even though `2026-05-25` is absent.
- `ROWS BETWEEN 6 PRECEDING AND CURRENT ROW` is the row-count alternative — **strict last 7 rows by position**. Use this only when you know there are no day gaps; if `2026-05-25` is missing, this frame at `2026-05-26` instead includes the 7 PHYSICAL ROWS ending at `2026-05-26`, which may span 8+ calendar days because of the gap. **This is the most common cause of "my 7-day rolling average looks wrong on holidays / weekends with no data" bugs.**

> **RANGE vs ROWS gap-day semantics — the rule.** For time-series rolling windows on dense daily data with **no missing days**, `RANGE BETWEEN INTERVAL '6' DAY PRECEDING` and `ROWS BETWEEN 6 PRECEDING` produce identical results. The instant any day is missing (a tenant with no events on Sundays, a holiday with zero traffic, a maintenance window) the two diverge:
>
> - **`RANGE` is calendar-aware** — `INTERVAL '6' DAY PRECEDING` always means "any row whose ORDER BY value (the `day` column) is between `current_day - INTERVAL '6' DAY` and `current_day`, inclusive." Missing days simply contribute zero rows to the frame; the value-based boundary is unchanged.
> - **`ROWS` is position-aware** — `6 PRECEDING` means "the 6 input rows immediately preceding this one in ORDER BY order." A gap shifts the frame backward by the count of the gap in physical rows.
>
> For SaaS analytics on DAU / MAU / revenue rollups where you frequently have missing days (holidays, idle tenants, ingestion blackouts), **default to `RANGE BETWEEN INTERVAL` over `ROWS BETWEEN N PRECEDING`**. The `RANGE` form requires the `ORDER BY` column to be one of: a numeric type (INTEGER, BIGINT, DOUBLE), a `DATE`, a `TIMESTAMP`, or a `TIMESTAMP WITH TIME ZONE`. The offset must be the matching `INTERVAL` type. Verified against [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html) — Trino supports `RANGE` value-based frames since the [March 2021 window-features release](https://trino.io/blog/2021/03/10/introducing-new-window-features.html).
>
> **Empty-frame edge case.** A `RANGE` frame can produce ZERO rows if the ORDER BY values around the current row don't fall inside the offset window. Window aggregates over an empty frame return: `COUNT()` -> 0, `SUM/AVG/MIN/MAX` -> NULL, `array_agg` -> NULL. Downstream consumers must handle NULL — `COALESCE(rolling_7d_avg_dau, 0)` is the standard guard. A `ROWS` frame **cannot** produce an empty frame at non-edge rows (it always has `N+1` rows), which is one reason engineers reach for it — but the cost is incorrect calendar semantics on sparse data.

### Performance: when window functions get expensive

Window functions force Trino to **sort the probe data** by `(PARTITION BY columns, ORDER BY columns)` before computing the window. This sort happens after `WHERE` filtering but before producing output. For large input sets the sort can spill to disk or OOM the worker.

Symptoms of a window-function memory problem:
- Trino UI shows the `Window` operator as the blocked stage with high memory usage.
- `EXPLAIN ANALYZE` shows large `Spilled` bytes on the Window operator (Trino uses ORC spill for window operators when enabled).
- The query passes a small test but times out on a year of data.

Mitigations, in order of preference:
1. **Tighten `WHERE`** to reduce the probe set before the window. A window over 30 days is fine; over 2 years probably is not. Always partition-prune on `day` / `occurred_at` first.
2. **Push to a pre-aggregated rollup table.** Rather than running a window over the raw fact table on every dashboard load, materialize a daily `agg_daily_revenue_by_tenant` table (one row per tenant per day) and run the window over the rollup. For a SaaS with 10k tenants × 365 days = 3.6M rows in the rollup vs 500M raw events, this is the difference between a 30-second query and a 0.5-second query.
3. **Narrow `PARTITION BY`.** Each unique partition key requires its own sort-and-window pass. `PARTITION BY tenant_id, user_id` on a high-cardinality table is far more expensive than `PARTITION BY tenant_id` alone.
4. **Enable Trino spill-to-disk** (`spill_enabled = true`, `query_max_total_memory_per_node` tuned) if you must run the window over the raw data. Spill trades latency for not OOMing.

### When to use a window function vs `GROUP BY`

| Need | Use |
|---|---|
| One row per group with an aggregate (total revenue per tenant) | `GROUP BY` |
| Every row PLUS an aggregate context (each order's amount AND tenant running total) | Window function |
| Top-N per group | Window function (`ROW_NUMBER`/`RANK`) + outer `WHERE` |
| Compare each row to the previous row in a group | `LAG` / `LEAD` |
| Aggregate over a moving window (last 7 days, last N rows) | Window function with frame clause |

If you can answer the question with `GROUP BY`, prefer it — `GROUP BY` collapses rows early and runs cheaper than a window function on the same data.

---

## Why each pattern stresses OLAP differently

| Pattern | Bottleneck | What helps |
|---|---|---|
| Aggregation | Wide scans | Columnar storage, partition pruning |
| Funnel | Multi-pass over same table | Caching, MATCH_RECOGNIZE, pre-aggregated funnel tables |
| Cohort | High-cardinality DISTINCT | `approx_distinct`, pre-built cohort tables |
| Time-series | Gap-filling logic | Calendar tables, dashboard-side fill |
| Window functions | Sort + memory on PARTITION BY / ORDER BY data | Tight `WHERE`, pre-aggregated rollup tables, narrower PARTITION BY |

Knowing which bottleneck you're hitting tells you where to optimize.
