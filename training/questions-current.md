# Iter 274 Questions

## Q1 — EXPLAIN plan confusion: where does filtering actually happen?

We set up Trino to query both Postgres (via the PostgreSQL connector) and our Iceberg tables on S3. I started running EXPLAIN on some of our slower cross-source queries and I'm getting back this wall of text with nodes like "TableScan," "ScanFilterProject," "Exchange," and "Aggregate." I can see numbers like "Input: 4200000 rows, Output: 312 rows" on some nodes.

What does it mean when a filter appears inside a "ScanFilterProject" node right next to the TableScan, versus when I see a separate Filter node higher up in the plan tree? I'm trying to figure out whether Trino is pushing my WHERE clause down into Postgres or pulling all 4 million rows over the network and then filtering them itself. How do I read the plan to know which one is happening?

## Q2 — Postgres connection exhaustion when dashboards run in parallel

We have maybe 15-20 customers all loading their dashboards at the same time during business hours. Some of these dashboards run Trino queries that join our Iceberg tables against a live Postgres table (for real-time account metadata). When load spikes, queries start backing up and some timeout.

I'm guessing Trino is opening JDBC connections to Postgres under the hood. How many connections does it open? Is there a connection pool I can configure, or does every Trino worker thread just open its own connection? And when things get backed up, does Trino queue the Postgres requests, or do they just fail immediately? I want to know what knobs to turn before I tell customers their dashboards are slow.
