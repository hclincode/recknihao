# Iter 310 Questions

Date: 2026-05-27
Topics: Multi-tenant CTAS exfiltration via scratch table + MinIO (Q1) + Postgres CDC replication slot WAL bloat (Q2)

## Q1 — Multi-tenant isolation edge case: can a customer exfiltrate data through their own queries?

We have the Trino view-per-tenant setup in place — each customer gets their own view that only shows their rows, and they can't access the base table directly. But I'm worried about a gap: when a customer runs an ad-hoc query (we let them run custom SQL through our dashboard), what stops them from doing something like `CREATE TABLE my_scratch AS SELECT * FROM events_customer_a` and then pulling the Parquet files out of MinIO directly? The view filters their tenant ID fine, but they'd own that scratch table and could do whatever with it. Is that a real risk, and how do you close it?

## Q2 — Postgres CDC pipeline: something about disk filling up?

We're setting up change-data-capture from our Postgres events table into Iceberg using Debezium. Someone on our team mentioned there's a classic outage scenario involving "replication slots" and disk space, and said it's the most common way CDC pipelines blow up in production. I don't fully understand what a replication slot does or why it would cause disk to fill up. Can you explain what's actually happening there and what we should do to protect ourselves?
