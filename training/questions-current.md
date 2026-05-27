# Iter 279 Questions

## Q1 — Stale dashboard data after Spark writes to Iceberg

We have a Spark pipeline that runs every 10 minutes and writes new rows into an Iceberg table on S3. The problem is that when I query that table through Trino right after the pipeline finishes, I sometimes still see the old data for another 10-15 minutes. If I restart the Trino coordinator, the fresh data shows up immediately. Is there some kind of cache that Trino is holding onto? I do not want to restart the coordinator every time our pipeline runs -- that would take down all our queries. Is there a way to tell Trino to refresh or drop whatever it is caching, maybe through a SQL command or some config we can tune?

## Q2 — Why does join order matter so much between Postgres and Iceberg tables

We noticed something weird with a query that joins a large Postgres events table (about 200M rows) against a small Iceberg lookup table (maybe 50k rows of customer segments). When we write the join with Iceberg on the right side, the query is fast -- maybe 8 seconds. But when we flip it so Postgres is on the right side and Iceberg is on the left, it gets really slow, like 2+ minutes. I figured joins were symmetric so this should not matter. Is Trino doing something special based on which table is on which side? Is there a way to control this behavior, or do we just have to remember to always write joins in a specific order?
