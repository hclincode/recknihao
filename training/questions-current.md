# Iter 307 Questions

Date: 2026-05-27
Topics: approx_percentile for p99 latency dashboards (Q1) + Parquet column storage and JSONB predicate pushdown (Q2)

## Q1 — approx_percentile vs exact percentile for p99 API latency

We're trying to show p99 API response time on our analytics dashboard. Someone on the team said we should use `approx_percentile` instead of the regular percentile function because it's way faster on large datasets. How do I know when that's actually okay to use versus when I need the exact number? And can I calculate p50, p95, and p99 in a single query, or do I have to run three separate ones?

## Q2 — Why does filtering by customer_id scan almost nothing, but filtering on a JSON column scans everything?

I noticed that when I filter my Iceberg table by something like `customer_id = 'abc123'`, the query is super fast and barely touches any data. But when I filter on a value that's inside a JSON column — like `WHERE json_col LIKE '%some_value%'` or even using a JSON extract function on it — it seems to read the whole table. Why does one work and the other doesn't? Does it have to do with how Parquet stores the data physically, or is something else going on?
