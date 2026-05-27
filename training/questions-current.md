# Iter 273 Questions

## Q1 — Querying across all tenant schemas in Postgres via Trino

We run a multi-tenant Postgres setup where each customer gets their own schema — so we have `tenant_abc.events`, `tenant_xyz.events`, and so on, maybe 200 schemas total. We connected Postgres to Trino as a catalog.

Now I want to run an aggregate across all tenants — like a platform-level report showing total events per tenant this week. In plain Postgres I'd probably write a loop or use `information_schema` to discover schemas dynamically. But when I try to do something like that in Trino it falls apart — I can't seem to pass a schema name as a variable.

Is there an actual way to query across all those tenant schemas from Trino, or do I need to go back to Postgres for that? If Trino can do it, what does that SQL actually look like?

## Q2 — Should I keep querying Postgres through Trino or copy the data into Iceberg?

Right now our Trino setup has two catalogs: one pointing at our Postgres database (where all the live app data lives), and one pointing at our Iceberg tables on S3 (where we've been loading some historical event data). Most of our analytics queries join between the two — like joining a Postgres `accounts` table with Iceberg `events`.

The queries work, but some of them are slow, and I'm not sure if it's because of the cross-catalog join or because Postgres just can't handle the scan volume. A coworker suggested we just copy the Postgres data into Iceberg so everything is in one place. But that feels like a big lift, and it means the Iceberg copy is always slightly behind the live data.

How do I figure out whether to keep federating from Postgres or move the data into Iceberg? What's the actual deciding factor?
