# Iter 292 Questions

## Q1 — Does using a CTE in Trino make it faster, or is it just for readability?

In Postgres, when I write a complex query, I sometimes break it into CTEs (the WITH ... AS ... part) to make it easier to read. I assumed Trino does the same thing — materialize the CTE result once and reuse it. But someone told me that in Trino, CTEs are NOT materialized by default and get inlined, which means if I reference the same CTE twice in a query, it actually runs that subquery twice. Is that true? And if so, should I be avoiding CTEs in Trino? We're running Trino 467 on Iceberg tables and I have some queries that reference the same CTE 2-3 times for different aggregations.

## Q2 — My query filters with HAVING but it still feels slow — is HAVING the same as WHERE in Trino?

I'm writing a query to find tenants who have more than 1000 events this week. I wrote it like this:

```sql
SELECT tenant_id, COUNT(*) AS event_count
FROM events
WHERE event_date >= DATE '2026-05-20'
GROUP BY tenant_id
HAVING COUNT(*) > 1000;
```

Someone told me HAVING is slower than WHERE for this kind of filter. But I don't see how — aren't HAVING and WHERE equivalent here? The COUNT has to happen before HAVING can evaluate, so how could I possibly avoid it?
