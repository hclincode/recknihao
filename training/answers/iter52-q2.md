# Iter52 Q2 Answer — Week-over-Week Comparison with LAG()

## The short answer

You can pull last week's count and the current week's count in the same query row without self-joining the table twice — by using the `LAG()` **window function**. In plain terms: `LAG()` lets you look back one row in an ordered result set so you can compare it to the current row. For weekly active users, you compute the current week's count, use `LAG()` to grab the prior week's count, and then subtract them.

---

## Why a self-join is messy (and how to avoid it)

Your instinct probably was: "I'll GROUP BY week to get this week's count, then join the same table grouped differently to get last week's count, then subtract." That works, but it's verbose and requires scanning the events table twice. Window functions do the same comparison in a single pass, once you understand the pattern.

---

## The pattern: LAG() over an ordered window

Here is the full example for your "weekly active users" dashboard:

```sql
WITH weekly AS (
  SELECT
    date_trunc('week', occurred_at) AS week_start,
    COUNT(DISTINCT user_id) AS wau
  FROM iceberg.analytics.events
  GROUP BY 1
)
SELECT
  week_start,
  wau,
  LAG(wau, 1) OVER (ORDER BY week_start) AS prior_week_wau,
  wau - LAG(wau, 1) OVER (ORDER BY week_start) AS wau_delta,
  ROUND(
    (wau - LAG(wau, 1) OVER (ORDER BY week_start)) * 100.0
    / NULLIF(LAG(wau, 1) OVER (ORDER BY week_start), 0),
    1
  ) AS wau_pct_change
FROM weekly
ORDER BY week_start;
```

**What this does:**

1. The `WITH weekly` CTE computes weekly active users the normal way: `GROUP BY date_trunc('week', occurred_at)`, count distinct users per week.
2. In the outer SELECT, `LAG(wau, 1) OVER (ORDER BY week_start)` looks at the result set of `weekly` (already grouped by week), sorts it by `week_start`, and for each row, returns the value from the previous row. "Previous row" = previous week.
3. `wau - LAG(...)` is the delta: this week minus last week.
4. The percentage change divides the delta by last week's count. The `NULLIF(..., 0)` prevents division-by-zero errors on the first week (where there is no prior week, so `LAG()` returns NULL).

**Plain-English explanation of `LAG(wau, 1) OVER (ORDER BY week_start)`:**

- `LAG(column_name, offset)` is a function that says: "for this row, give me the value of `column_name` from `offset` rows back in the sorted order."
- `LAG(wau, 1)` = "give me the `wau` value from 1 row back" = "give me last week's count."
- `OVER (ORDER BY week_start)` tells Trino: "sort the rows by `week_start` before applying LAG."
- The first row will show NULL for `prior_week_wau` — there is no week before the first week — and that's expected and correct.

---

## Other useful window functions

- **`LEAD(wau, 1) OVER (ORDER BY week_start)`** — the opposite of LAG. Looks *forward* one row instead of back. Useful for "next week's forecast" or trailing indicators.
- **`ROW_NUMBER() OVER (ORDER BY week_start)`** — assigns 1, 2, 3, ... to rows in order. Useful for filtering to "only keep the 10 most recent weeks."
- **`NTILE(4) OVER (ORDER BY wau)`** — divides rows into N percentile buckets (quartiles, deciles, etc.). Useful for "which weeks were in the top 25% for signups?"

---

## Example output

| week_start | wau | prior_week_wau | wau_delta | wau_pct_change |
|---|---|---|---|---|
| 2026-05-01 | 1000 | NULL | NULL | NULL |
| 2026-05-08 | 1120 | 1000 | 120 | 12.0 |
| 2026-05-15 | 1050 | 1120 | -70 | -6.3 |
| 2026-05-22 | 1200 | 1050 | 150 | 14.3 |

---

## Production note: partition pruning

When you run this on a large events table, add a date filter to the `WITH weekly` CTE so Trino can skip files outside your query window:

```sql
WHERE occurred_at >= current_date - INTERVAL '13' WEEK
```

Without this filter, Trino scans the entire table even though you only care about recent weeks. With the filter, Iceberg's partition pruning skips old files and the query runs 10–100× faster.

---

## Summary

`LAG()` is a window function that references a value from a previous row in an ordered result set. For weekly active users, GROUP BY week to compute WAU, then use `LAG(wau, 1) OVER (ORDER BY week_start)` to grab last week's value in the same row. `wau - prior_week_wau` and percentage change are then just arithmetic. This avoids a self-join and keeps the query readable.
