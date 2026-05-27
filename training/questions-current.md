# Iter 293 Questions

## Q1 — Window functions vs GROUP BY: when should I use one over the other?

I'm trying to add a "running total" feature to our analytics — showing cumulative revenue per tenant over time. In Postgres I'd use a window function (`SUM(amount) OVER (PARTITION BY tenant_id ORDER BY event_date)`). But I've also seen people do this with self-joins or GROUP BY + subquery. I'm not sure which approach Trino handles better on Iceberg tables. Does Trino support window functions? And is there a meaningful performance difference between a window function and a GROUP BY approach for this use case?

## Q2 — What does SELECT * actually cost me in Trino vs Postgres?

I know "don't use SELECT *" is standard advice, but I want to understand what the actual cost is. In Postgres, SELECT * vs SELECT col1, col2 doesn't matter much because the page is fetched anyway and you're just getting more columns from it. In Trino querying Iceberg, I've heard it's different because of columnar storage. Can you explain what actually happens in the file format when I do SELECT * versus naming specific columns — like, at what layer does Trino stop reading data it doesn't need?
