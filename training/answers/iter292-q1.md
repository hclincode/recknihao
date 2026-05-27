# Iter292 Q1 — Are CTEs Materialized or Inlined in Trino?

## Short answer

CTEs in Trino are **inlined, not materialized by default.** If you reference the same CTE twice in a query, the subquery executes twice. You should not avoid CTEs — but you should understand when they double-execute and how to fix that pattern.

## How CTEs work in Trino

In Postgres, CTEs are materialized: the result is computed once, stored temporarily, and reused. Trino is different — the optimizer inlines CTEs, substituting the named subquery wherever it appears.

**Example — CTE referenced twice, executes twice:**

```sql
WITH recent_events AS (
  SELECT user_id, COUNT(*) AS event_count
  FROM events
  WHERE event_date = DATE '2026-05-26'
  GROUP BY user_id
)
SELECT
  (SELECT SUM(event_count) FROM recent_events) AS total_events,
  (SELECT COUNT(*) FROM recent_events) AS unique_users;
```

Trino inlines `recent_events` twice. The scan + GROUP BY runs twice. On a large Iceberg table this doubles your I/O and compute cost.

## When CTEs are free to use

**Single-reference CTEs: no penalty.** Inlining once is equivalent to writing the subquery inline. Use CTEs freely for readability when you reference them once:

```sql
WITH filtered AS (
  SELECT user_id, event_type, amount
  FROM events
  WHERE event_date = DATE '2026-05-26'
)
SELECT user_id, SUM(amount)
FROM filtered
WHERE event_type = 'purchase'
GROUP BY user_id;
```

This is inlined once. Trino can also combine the two WHERE predicates into a single Iceberg scan — no extra cost.

## The fix for multi-reference CTEs

**Option 1 (preferred): collapse into a single query**

```sql
-- Instead of referencing the same CTE twice for two aggregations:
SELECT
  COUNT(DISTINCT CASE WHEN event_type = 'purchase' THEN user_id END) AS purchase_users,
  COUNT(DISTINCT CASE WHEN event_type = 'signup'   THEN user_id END) AS signup_users
FROM events
WHERE event_date = DATE '2026-05-26';
```

Single scan, both aggregates computed in one pass. Use `CASE WHEN` inside aggregate functions to compute multiple things from one scan.

**Option 2: materialize for cross-query reuse**

If the CTE is genuinely expensive and you need to query it multiple times across separate statements:

```sql
CREATE TABLE temp.recent_events_extract AS
SELECT user_id, event_type, amount
FROM events
WHERE event_date = DATE '2026-05-26';

-- Now reference it as many times as needed — computed once
SELECT COUNT(DISTINCT user_id) FROM temp.recent_events_extract WHERE event_type = 'purchase';
SELECT COUNT(DISTINCT user_id) FROM temp.recent_events_extract WHERE event_type = 'signup';

DROP TABLE temp.recent_events_extract;
```

This is the recommended pattern for expensive multi-step pipelines that need intermediate results reused across multiple queries.

## For your specific situation (2–3 CTE references for different aggregations)

The collapse-to-single-query approach is almost always right:

```sql
SELECT
  COUNT(DISTINCT CASE WHEN event_type = 'purchase' THEN user_id END) AS purchase_users,
  COUNT(DISTINCT CASE WHEN event_type = 'signup'   THEN user_id END) AS signup_users,
  COUNT(DISTINCT CASE WHEN event_type = 'view'     THEN user_id END) AS view_users
FROM events
WHERE event_date >= DATE '2026-05-20'
  AND event_date <  DATE '2026-05-27';
```

One scan, three aggregates, no double-execution.

## Should you avoid CTEs?

No. CTEs are valuable for:
- **Readability** — naming intermediate steps makes complex queries understandable
- **Correctness** — avoids copy-paste errors in duplicated subqueries
- **No penalty for single-use** — inlining a CTE once costs nothing

The habit to build: recognize when you reference a CTE more than once, and collapse those uses into a single aggregation query.

## Verifying with EXPLAIN

```sql
EXPLAIN
WITH heavy AS (SELECT user_id, SUM(amount) FROM events WHERE event_date = DATE '2026-05-26' GROUP BY user_id)
SELECT (SELECT COUNT(*) FROM heavy), (SELECT MAX(amount) FROM heavy);
```

If the scan appears twice in the EXPLAIN output, the CTE is being inlined and executed twice — time to collapse.
