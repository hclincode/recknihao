# Iter 298 Questions

## Q1 — Iceberg table maintenance without Spark

We've been running Iceberg on top of Trino for about two months and our S3 costs keep climbing. I looked it up and it sounds like we need to do some kind of "snapshot expiration" or cleanup, but everything I find on the Iceberg docs talks about running maintenance through Spark — we don't have Spark in our stack at all, we only have Trino. Do we actually need to spin up a Spark cluster just to run cleanup jobs, or is there a way to do this directly from Trino? We're trying to avoid adding another system if we can help it.

## Q2 — Filtering on a column with no index is fast in Iceberg but kills Postgres

We have a Postgres table with about 80 million rows of customer event data. When we filter by `event_type = 'page_view'` it does a full sequential scan and the query takes 45 seconds, even though that column has low cardinality and it feels like it should be easy to skip rows. I added a B-tree index on `event_type` but for high-cardinality filters the planner sometimes ignores it anyway. I keep hearing that columnar formats like Parquet handle this kind of filtering much better — is that actually true, and if so how does it work? Is Parquet just doing what an index does, or is it something different?
