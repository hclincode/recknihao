# Iter293 Q1 — Window Functions vs GROUP BY for Running Totals in Trino

## Short answer

Yes, Trino fully supports window functions. For cumulative revenue (running total), window functions are the correct and only straightforward approach. GROUP BY collapses rows — it can't express running totals without complex self-joins that are far more expensive.

## Window functions in Trino 467

Trino supports standard ANSI SQL window functions including `SUM(...) OVER (PARTITION BY ... ORDER BY ...)`, `ROW_NUMBER()`, `RANK()`, `LAG()`, `LEAD()`, and others. They work directly on Iceberg tables.

**Your running total query:**

```sql
SELECT
  tenant_id,
  event_date,
  amount,
  SUM(amount) OVER (
    PARTITION BY tenant_id
    ORDER BY event_date
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS cumulative_revenue
FROM iceberg.analytics.revenue_events
WHERE event_date >= CURRENT_DATE - INTERVAL '90' DAY
ORDER BY tenant_id, event_date;
```

This keeps one row per event with a cumulative sum column — exactly what you want.

## Why GROUP BY can't express running totals

GROUP BY collapses multiple rows into one row per group. Running totals require keeping each individual row AND computing an aggregate over all preceding rows for that tenant. These are fundamentally incompatible — GROUP BY destroys the row-level detail that the running total needs to order by.

The only GROUP BY alternative would be a self-join:
```sql
-- DO NOT DO THIS — Cartesian product nightmare
SELECT a.tenant_id, a.event_date, SUM(b.amount) AS cumulative_revenue
FROM revenue_events a
JOIN revenue_events b
  ON a.tenant_id = b.tenant_id
  AND b.event_date <= a.event_date
GROUP BY a.tenant_id, a.event_date;
```

This joins each event against all prior events for that tenant — O(n²) data movement. For 1M events per tenant, this creates 1 trillion row comparisons. A window function scans the data once and computes the cumulative sum in a single pass.

## Performance considerations

**Window functions are memory-intensive.** The window operator holds the entire partition (all events for a tenant) in memory to compute the running sum. For very large datasets:

- If you exceed Trino worker memory, the operator spills to local disk (`spill-enabled=true` in config.properties). Slower, but the query completes.
- If spill isn't configured, you'll see `EXCEEDED_LOCAL_MEMORY_LIMIT` and the query fails.

**For production dashboards with this pattern**, consider pre-computing running totals nightly:

```sql
-- dbt model: cumulative_revenue_daily
SELECT
  tenant_id,
  event_date,
  SUM(daily_revenue) OVER (
    PARTITION BY tenant_id
    ORDER BY event_date
  ) AS cumulative_revenue
FROM daily_revenue_rollup;
```

Then the dashboard query reads a pre-aggregated table instead of computing over raw events live.

## Practical recommendation

Use window functions for running totals — they're the right tool and Trino 467 handles them well for typical SaaS volumes (millions to low billions of rows). For very large tenant histories or live dashboard performance, pre-aggregate nightly and query the rollup.

Also: run `ANALYZE TABLE iceberg.analytics.revenue_events` after large ingests so the cost-based optimizer has accurate statistics for the window operator's memory planning.
