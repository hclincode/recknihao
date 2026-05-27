# Iter 320 Questions

Date: 2026-05-27
Topics: NOT NULL constraint addition in CDC pipeline (Q1) + View-per-tenant vs OPA row-level filtering at scale (Q2)

## Q1 — Postgres-to-Iceberg ingestion: NOT NULL constraint addition in CDC pipeline

We've been using Debezium to stream changes from Postgres into our Iceberg tables. Everything was fine until one of our backend engineers added a `NOT NULL` constraint to an existing column in Postgres — just added it, no data change, no new column. After that, our CDC pipeline started throwing errors and we had to manually restart the Debezium connector. I don't understand why a constraint change on the Postgres side would blow up the ingestion side. Does Debezium actually capture constraint changes as events, and if so, how should we be handling this so it doesn't take down the pipeline?

## Q2 — Multi-tenant analytics: View-per-tenant vs OPA row-level filtering at scale

Right now we have about 200 tenants and we're using a separate view per tenant in Trino to control data access — each tenant's users only query through their view. It works but our ops team is complaining that every time we onboard a new tenant, someone has to manually create the view, and we're worried about what happens when we hit 500 or 1,000 tenants. Someone on the team mentioned we could use OPA (which we already have in our stack) to do row-level filtering instead of separate views. What's the actual performance difference between the view-per-tenant approach and row-level filtering through OPA at that scale? I'm trying to figure out at what point the view approach breaks down and whether switching to OPA filters is actually faster or just easier to manage.
