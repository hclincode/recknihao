# Iter 305 Questions

Date: 2026-05-27
Topics: Trino resource groups (Q1) + Partition strategy for multi-tenant SaaS events table (Q2)

## Q1 — Trino resource groups: stopping ingestion from starving dashboards

We have one Trino cluster that both our customer dashboards and our nightly data loading jobs hit at the same time. Lately when the ingestion jobs are running, our dashboard queries start timing out or just crawl. Someone said we should configure something called "resource groups" in Trino. What does that actually do? Is it just a queue, or does it actually give different jobs different amounts of memory or CPU? And how do we set it up so dashboards always get served even when ingestion is hammering the cluster?

## Q2 — How to partition a new multi-tenant SaaS events table

We're setting up a new table to store customer activity events — columns like `tenant_id`, `event_type`, `occurred_at` (timestamp), and `user_id`. We expect each tenant to have wildly different event volumes. Before we load data, we need to decide how to partition this table, and we have no idea how to think about it. Should we partition by tenant? By date? Both? Does it even matter if we're using something like Iceberg? What's the actual decision process here?
