# Iter 295 Questions

## Q1 — Our users table has a plan column, but users change plans over time — how do I answer "who was on Pro last quarter"?

We have a users table in Iceberg that includes a `plan_name` column (Free, Pro, Enterprise). We sync it from Postgres nightly. The problem is when a user upgrades from Free to Pro mid-quarter and then back to Free, our nightly snapshot just overwrites the old value. So when a customer asks "how many users were on the Pro plan last quarter," we can't answer accurately because we only have today's plan. Someone mentioned we need to track "history" for this column but I have no idea what that looks like in practice. How do we store and query a column that changes over time?

## Q2 — I'm setting up partitioning on our Iceberg events table and I don't know how to choose between the different partitioning options I keep seeing in examples.

We have an events table in Iceberg — about 2 billion rows — with columns like `occurred_at` (timestamp), `tenant_id` (we have ~800 tenants), and `user_id` (about 5 million distinct values). I've seen examples partition by the date, others by tenant, and one example partitioned by user_id. I don't know how to decide which column to partition on or whether I can use multiple. Also I keep seeing `bucket(user_id, 16)` in some docs and `day(occurred_at)` in others — what do those mean and which approach is right for a multi-tenant SaaS events table?
