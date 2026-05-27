# Iter 321 Questions

Date: 2026-05-27
Topics: Column rename detection in CDC pipeline (Q1) + Time-travel snapshot storage cost (Q2)

## Q1 — Postgres-to-Iceberg ingestion: column rename detection in CDC

We're using Debezium to stream changes from Postgres into our Iceberg tables, and last week someone on the backend team renamed a column in one of our Postgres tables. It was a straightforward rename, just updating a field name for clarity. Our CDC pipeline kept running without any obvious errors, but when we queried the Iceberg table we realized the old column name was still there and the new column's data wasn't showing up anywhere. How does Debezium actually handle a column rename in Postgres — does it detect it as a rename, or does it see it as something else entirely? And what's the safe way to handle this if we need to rename columns in Postgres without silently breaking the Iceberg side?

## Q2 — Storage sizing: time-travel snapshot storage cost

We turned on time-travel for our Iceberg tables a few months ago because it sounded useful — customers could query historical snapshots. But now our MinIO storage costs are climbing faster than our actual data growth, and I'm trying to figure out why. I think it's related to how Iceberg keeps old snapshots around, but I'm not sure exactly what's being stored or how to reason about the cost. If we have a table that gets updated heavily every day, how do I estimate how much extra storage time-travel is adding, and what's the tradeoff if we shorten how long we keep snapshots?
