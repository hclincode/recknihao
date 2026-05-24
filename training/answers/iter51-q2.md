# Iter51 Q2 Answer — Cohort retention query in Trino

**Question**: Build a retention analysis: of users who had their first event in a given week, what % came back 7, 30, 90 days later? Show the SQL pattern in Trino.

---

## The pattern: three CTEs

A cohort retention query has three phases, each a normal `GROUP BY` you already know how to write. The new piece is using `date_diff()` to measure the gap between events.

```sql
WITH first_events AS (
  -- Phase 1: Find each user's first event and what week it was
  SELECT 
    user_id,
    date_trunc('week', MIN(occurred_at)) AS cohort_week,
    MIN(occurred_at)                     AS first_event_at
  FROM iceberg.analytics.events
  GROUP BY user_id
),

cohort_sizes AS (
  -- Phase 2: How many users had their first event in each week? (denominator)
  SELECT 
    cohort_week,
    COUNT(DISTINCT user_id) AS total_users
  FROM first_events
  GROUP BY cohort_week
),

returns AS (
  -- Phase 3: For each cohort week, count users who returned in each window
  SELECT 
    f.cohort_week,
    SUM(CASE WHEN date_diff('day', f.first_event_at, e.occurred_at) BETWEEN 1 AND 7  THEN 1 ELSE 0 END) AS returned_7d,
    SUM(CASE WHEN date_diff('day', f.first_event_at, e.occurred_at) BETWEEN 1 AND 30 THEN 1 ELSE 0 END) AS returned_30d,
    SUM(CASE WHEN date_diff('day', f.first_event_at, e.occurred_at) BETWEEN 1 AND 90 THEN 1 ELSE 0 END) AS returned_90d
  FROM first_events f
  JOIN iceberg.analytics.events e ON e.user_id = f.user_id
  GROUP BY f.cohort_week
)

SELECT 
  c.cohort_week,
  c.total_users,
  ROUND(100.0 * r.returned_7d  / c.total_users, 1) AS pct_retained_7d,
  ROUND(100.0 * r.returned_30d / c.total_users, 1) AS pct_retained_30d,
  ROUND(100.0 * r.returned_90d / c.total_users, 1) AS pct_retained_90d
FROM cohort_sizes c
JOIN returns r ON r.cohort_week = c.cohort_week
WHERE date_diff('day', c.cohort_week, current_date) >= 90  -- only show cohorts old enough to measure
ORDER BY c.cohort_week DESC;
```

**Example output:**
```
cohort_week | total_users | pct_retained_7d | pct_retained_30d | pct_retained_90d
2026-02-23  |    1,200    |      62.5       |       49.2       |       43.3
2026-02-16  |      980    |      61.2       |       51.0       |       44.5
```

## How each piece works

**`first_events` CTE** — This is a standard `GROUP BY user_id` where instead of `COUNT(*)` you take `MIN(occurred_at)`. Every user appears once, labeled with the week they first showed up.

**`cohort_sizes` CTE** — Another standard `GROUP BY cohort_week` counting distinct users per week. This is your denominator for percentages.

**`returns` CTE — the new pattern:**
```sql
date_diff('day', f.first_event_at, e.occurred_at) BETWEEN 1 AND 7
```
- `date_diff('day', ts1, ts2)` — Trino's function to compute "how many days from ts1 to ts2?" (returns ts2 - ts1; NOT DATEDIFF which is MySQL syntax)
- `BETWEEN 1 AND 7` — at least 1 day later (excludes the signup event itself) and at most 7 days
- `SUM(CASE WHEN ... THEN 1 ELSE 0 END)` — count rows where the condition is true; this is the Trino way to do conditional counting

The `JOIN iceberg.analytics.events e ON e.user_id = f.user_id` brings every event back in for each user. For each event, the CASE WHEN measures whether it falls in the 7/30/90-day window. Then `GROUP BY f.cohort_week` aggregates per cohort.

## Customizing for your data

**Count only specific events** — add to the JOIN condition:
```sql
JOIN iceberg.analytics.events e ON e.user_id = f.user_id AND e.event_name = 'dashboard_viewed'
```

**Change cohort granularity** — replace `'week'` with `'month'` or `'day'` in `date_trunc`.

**Exclude same-day events** — `BETWEEN 1 AND 7` already excludes day 0. Change to `<= 7` if you want to count same-day returns.

## The incomplete-data gotcha

The `WHERE date_diff('day', c.cohort_week, current_date) >= 90` filter is important: a cohort from last week can't have 90-day retention yet. Without this filter, those cohorts show artificially low percentages and make your chart look like retention is falling.

## Performance

This query scans the events table twice (once for first events, once for all events in the return CTE). For hundreds of millions of rows, expect 15–30 seconds. For a daily-running dashboard, pre-compute the result into a materialized Iceberg table so you're not re-running the full scan on every page load. Verify the numbers are correct first with the raw query, then materialize.
