# Iter 275 Questions

## Q1 — Cross-catalog writes and what happens when one side fails

We have Trino set up to query both our Postgres database and an Iceberg table on S3. A feature I'm building needs to write to both at the same time — update a row in Postgres and also append a record to Iceberg to keep an audit log in sync. I want to do this in one shot rather than making two separate calls from my application. Can Trino handle that? And if Trino writes to Postgres successfully but then the Iceberg write fails, what actually happens — does Postgres roll back, or am I left with half-committed data?

## Q2 — Spotting slow Postgres scans in the Trino Web UI

We've noticed some of our federated queries — ones that join Postgres tables against Iceberg — are slower than expected. Someone told me Trino has a Web UI where I can inspect what's going on. What does that UI actually show me for a query like this? I'm specifically trying to figure out whether the slowness is coming from Trino pulling too much data out of Postgres before filtering it. Is there a way to see in the UI how many rows came back from the Postgres side, without having to run an EXPLAIN statement?
