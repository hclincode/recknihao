# Iter 294 Questions

## Q1 — Should I normalize or denormalize my Iceberg tables? Coming from a relational database mindset.

In Postgres we normalize everything — customers, orders, and line items are separate tables with foreign keys. We joined them at query time. Now we're moving some of this to Iceberg for analytics, and I'm not sure if I should keep the same normalized structure or flatten everything into one wide table. Someone mentioned "star schema" but I don't really know what that is. How should I think about data modeling for analytics vs OLTP?

## Q2 — Our analytics tables have hundreds of columns and I'm not sure which ones to put in the fact table vs a separate dimension table.

We have a usage events table that tracks every action a user takes — it has event metadata (timestamp, type, session_id), user attributes (plan, region, company_size), and product attributes (feature_name, module, version). Right now it's all one big table. Someone said we should split it into a fact table and dimension tables. What's the rule for deciding what goes where, and what would that look like for our events use case?
