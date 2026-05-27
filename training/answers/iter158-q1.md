# Iter 158 Q1 — Trino Federation: Querying Postgres Directly from Trino

## Answer

## Yes, Trino can query Postgres directly — it's real

Your team member is correct. Trino has connectors that let you point it at an external database like Postgres and write SQL that queries it directly, without any backend joining. In one SQL statement, you can JOIN data from your Postgres app database with data in your Iceberg tables on MinIO.

## But here's the critical catch

The resources I have don't deeply cover Trino's Postgres connector performance characteristics, so I can't give you a complete answer about the exact costs and behavior. But based on the production architecture described and the ingestion patterns documented, I can tell you the real concern:

**Trino will pull Postgres data across the network for every query.**

When you run a query that JOINs your Iceberg table with a Postgres table via Trino, Trino needs to:
1. Send a query to Postgres
2. Get the full result set back over the network
3. Join it in Trino's memory with the Iceberg data

On a table with a few million rows, this is **slow and expensive**. You're streaming data you've already ingested (Postgres is your OLTP source) back across the network to join it with analytics data. That defeats the whole purpose of having an OLAP system.

## What you should actually do

The resources show a better pattern: **ingest Postgres data INTO Iceberg on a schedule** (hourly or daily depending on your freshness needs), then query only Iceberg in Trino.

Your production stack has multiple ingestion patterns documented:
- **Hourly incremental Spark jobs** reading from a Postgres read-replica, writing to Iceberg. This is the most common starting point.
- **Debezium + Kafka CDC** for sub-minute freshness if you genuinely need it (most teams don't at the start).

Once the data is in Iceberg, all your queries run fast because they're hitting columnar Parquet files on MinIO, not network-round-tripping to Postgres.

## Why not just query Postgres directly from your Node backend?

Your current approach (two separate queries, joined in Node) is actually the honest solution if you need **true real-time** consistency between app state and analytics. The problem is it's slow and fragile. Ingesting to Iceberg solves the speed problem but trades real-time consistency for freshness (hourly lag, typically). That's the right trade for 99% of SaaS analytics use cases.

**Bottom line:** Yes, Trino can do it. But don't. Ingest to Iceberg on a schedule instead.
