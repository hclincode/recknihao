# Iter 302 Questions

## Q1 — Denormalize plan/tier info into events table or join at query time?

We have an events table in Iceberg that tracks every action a user takes in our product. We also have a customer_accounts table (currently in Postgres) that has fields like plan_tier, company_size, and signup_date. A lot of our dashboard queries need to filter or group by plan_tier — like "show me funnel completion rates broken down by Free vs Pro vs Enterprise." Right now we do a federated join from Trino hitting both Iceberg and Postgres, but it feels fragile and slow. Someone on the team suggested we just copy plan_tier and company_size directly into every row of the events table when we ingest. Is that a good idea? What are the downsides if a customer upgrades their plan — do we have to backfill millions of rows?

## Q2 — COUNT(DISTINCT user_id) is destroying our query performance on 500M rows

We have a query that counts unique active users per day across our full events table, which is now around 500 million rows. The query runs fine on a 30-day window but when a customer asks for a 12-month trend with COUNT(DISTINCT user_id) grouped by day, it sometimes takes 3-4 minutes or just times out entirely. Our Trino cluster is not small — we have decent resources. Is this a fundamental problem with how COUNT(DISTINCT) works at this scale, or is there something wrong with our query or table setup? I've heard there are "approximate" versions of these functions — are those actually trustworthy enough to show to customers, and how far off are they typically?
