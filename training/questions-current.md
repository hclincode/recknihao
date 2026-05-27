# Iter 289 Questions

## Q1 — Query is slow even though I filtered by date — is something ignoring my WHERE clause?

So I have an Iceberg table that's partitioned by day on an `event_time` column — at least that's how I think it was set up. I'm running a Trino query to pull usage events for the last 30 days, and I wrote the WHERE clause like this:

```sql
WHERE DATE(event_time) >= DATE('2026-04-27')
```

The query works and returns correct results, but it's scanning way more data than I'd expect — I can see it in the Trino UI, it's touching hundreds of files across every partition going back months. In Postgres I never had to think about stuff like this — if I filtered on a column, it used the index. Is wrapping the column in `DATE()` somehow preventing Trino from skipping old partitions? Should I be writing this filter differently? I'm not sure if there's a "right" way to filter on dates in Trino that keeps the scan fast.

## Q2 — COUNT(DISTINCT user_id) takes forever — is there a faster version that's "close enough"?

We have a query that counts unique active users per tenant per week, and it's running `COUNT(DISTINCT user_id)` over about 300 million rows in Iceberg. It's painfully slow — sometimes 90+ seconds. Someone on the team mentioned there might be an approximate version of this that runs much faster but gives you a number that's like 99% accurate. Is that a real thing in Trino? And if I switch to it, how do I know what tradeoff I'm actually making — is it off by a few rows, or could it be off by thousands?

Also separately: I've heard I should run EXPLAIN on my queries before just firing them, but when I do it in Trino I get this big tree of output that doesn't look anything like what Postgres EXPLAIN gives me. Is there something specific I should be looking for in Trino's EXPLAIN to tell if a query is going to be expensive before I run it?
