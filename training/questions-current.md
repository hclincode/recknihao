# Iter 318 Questions

Date: 2026-05-27
Topics: Schema evolution mid-CDC-pipeline — ADD COLUMN in Postgres (Q1) + OPA row-filter performance under high concurrency (Q2)

## Q1 — Schema evolution mid-CDC-pipeline: ADD COLUMN in Postgres

We're using Debezium to stream changes from our Postgres database into our data pipeline, and everything has been working fine. Last week, one of our teams added two new columns to one of the Postgres tables we're streaming from — just a regular `ALTER TABLE ... ADD COLUMN`. Nobody touched the Debezium connector config. Now some downstream consumers are saying they see the new columns in the Kafka messages, but when we check the Iceberg table on the other end, the new columns aren't there. The rows that came in after the ALTER still seem to be landing, but without those columns. What actually happens to a CDC pipeline when you change the Postgres table schema mid-stream — does Debezium automatically pick up new columns, and if not, what do we need to do manually to get the Iceberg table updated and the data flowing correctly?

## Q2 — OPA row-filter performance under high concurrency

We have around 200 tenants on our platform and we're using OPA to control which rows each tenant can see when they query through Trino. It mostly works, but under load — say 50-80 concurrent users across tenants hitting the dashboard at the same time — query latency jumps noticeably, sometimes 2-3x slower than when traffic is light. We're trying to figure out if OPA is the bottleneck. Specifically: when a Trino query runs, is OPA being called once per query to decide what that tenant can see, or is it somehow getting called per row, or per something else? And if OPA is the bottleneck, what do we actually tune — is it the OPA server itself, or is there something in how Trino is configured to call it?
