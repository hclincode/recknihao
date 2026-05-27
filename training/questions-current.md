# Iter 271 Questions

## Q1 — Is my WHERE clause actually filtering in Postgres or is Trino pulling everything first?

We set up Trino with the PostgreSQL connector pointing at our app database, and separately we have an Iceberg catalog for our event data. The idea was to run queries that join Postgres user records to Iceberg events without having to copy everything to one place first.

The problem I'm running into is that some queries against the Postgres-backed tables feel suspiciously slow — like they're reading way more data than they should. For example, I'm filtering on `tenant_id = 'abc123'` and `created_at > now() - interval '30' day`, and that should use an existing Postgres index. But the query is still slow.

How do I actually tell whether Trino is pushing those WHERE conditions down into Postgres (so Postgres does the indexed lookup), versus Trino fetching a huge chunk of rows and then filtering them itself? Is there something in EXPLAIN I should look at?

## Q2 — Postgres has a column with type `jsonb` — does Trino just break or quietly lose data?

Our Postgres schema has a few columns that aren't simple types. We have a `metadata` column typed as `jsonb`, a `user_id` column typed as `uuid`, and an `account_status` column that's a custom enum we defined in Postgres. When I query these tables through Trino's PostgreSQL connector, I want to understand what actually happens.

Does Trino refuse to read those columns and throw an error? Does it silently skip them and return the row without those columns? Or does it try to cast them to something else? I'm worried we might be getting wrong results without realizing it — like if `uuid` gets coerced to a string, maybe that's fine, but if `jsonb` gets dropped entirely, that would be a real problem for some of our queries.
